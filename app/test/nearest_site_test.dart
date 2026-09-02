/// Picking the radar the app opens on.
///
/// The probe is injected, so these run the real ranking against the real
/// station list without touching the network — which is the point of putting
/// the choice in `lib/data/` instead of inside the workspace widget.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/nearest_site.dart';
import 'package:radar_app/data/nexrad_sites.g.dart';

void main() {
  // Norman, Oklahoma. The case from #37, and worse than the issue described:
  // the two closest sites are both non-publishing research radars -- KOUN
  // (NSSL) and KCRI (the ROC's redundant test RDA), within about a kilometre
  // of each other -- and the operational KTLX is only third.
  const normanLat = 35.22;
  const normanLon = -97.44;

  group('ranking', () {
    test('KOUN really is nearer to Norman than KTLX', () {
      final ranked = sitesByDistance(normanLat, normanLon);
      final koun = ranked.indexWhere((s) => s.icao == 'KOUN');
      final ktlx = ranked.indexWhere((s) => s.icao == 'KTLX');
      expect(koun, isNonNegative, reason: 'KOUN is in the station list');
      expect(ktlx, isNonNegative);
      expect(koun, lessThan(ktlx), reason: 'which is why distance alone fails');
    });

    test('TDWR sites are never offered', () {
      final ranked = sitesByDistance(normanLat, normanLon);
      expect(ranked.any((s) => s.isTdwr), isFalse);
      expect(ranked, isNotEmpty);
    });

    test('ordering is nearest first', () {
      final ranked = sitesByDistance(normanLat, normanLon);
      expect(ranked.take(3).map((s) => s.icao), ['KOUN', 'KCRI', 'KTLX']);
    });
  });

  group('probing', () {
    /// The real Norman case: walk past both research radars to the
    /// operational one, which is what the user actually wanted to open on.
    test('silent sites are skipped until one answers', () async {
      const silent = {'KOUN', 'KCRI'};
      final asked = <String>[];
      final site = await nearestPublishingSite(
        normanLat,
        normanLon,
        publishes: (s) async {
          asked.add(s.icao);
          return !silent.contains(s.icao);
        },
      );
      expect(site.icao, 'KTLX');
      expect(asked, ['KOUN', 'KCRI', 'KTLX'],
          reason: 'tried in order, stopping at the first that answers');
    });

    test('a publishing nearest site is taken without probing further',
        () async {
      final asked = <String>[];
      final site = await nearestPublishingSite(
        normanLat,
        normanLon,
        publishes: (s) async {
          asked.add(s.icao);
          return true;
        },
      );
      expect(site.icao, 'KOUN');
      expect(asked, ['KOUN'], reason: 'one probe, not a sweep of the network');
    });

    /// Offline, every probe fails. Opening on a plausible radar and letting
    /// the pane report its own error beats opening on a site chosen for no
    /// reason, or on nothing at all.
    test('when nothing answers it falls back to the geometric nearest',
        () async {
      final site = await nearestPublishingSite(
        normanLat,
        normanLon,
        publishes: (_) async => false,
      );
      expect(site.icao, 'KOUN');
      expect(site.icao, nearestSite(normanLat, normanLon).icao);
    });

    /// A cold start must not turn into a sweep of the whole network when the
    /// user is somewhere with no working radar nearby.
    test('probing is bounded', () async {
      var probes = 0;
      await nearestPublishingSite(
        normanLat,
        normanLon,
        maxProbes: 3,
        publishes: (_) async {
          probes++;
          return false;
        },
      );
      expect(probes, 3);
    });

    /// Norman needs three probes to reach KTLX, so the default has to leave
    /// room for it. This is the test that fails if someone tunes it down.
    test('the default reaches the operational radar at Norman', () async {
      const silent = {'KOUN', 'KCRI'};
      final site = await nearestPublishingSite(
        normanLat,
        normanLon,
        publishes: (s) async => !silent.contains(s.icao),
      );
      expect(site.icao, 'KTLX');
    });

    /// Startup blocks on this before the panes may load, so a network that
    /// never answers must not hold the app on a blank screen while every
    /// probe times out in turn.
    test('a hung network gives up on budget and uses the nearest', () async {
      final site = await nearestPublishingSite(
        normanLat,
        normanLon,
        budget: const Duration(milliseconds: 60),
        publishes: (_) => Future.delayed(
          const Duration(seconds: 30),
          () => true,
        ),
      );
      expect(site.icao, 'KOUN', reason: 'the geometric nearest, as before');
    });

    /// KJKL (Jackson, Kentucky) is operational but can be silent — down for
    /// maintenance, or simply not publishing today. A hand-curated list of
    /// "sites that never publish" would not contain it and would not help;
    /// probing handles it the same way it handles KOUN.
    test('a temporarily silent operational site is handled too', () async {
      final jackson = nexradSites.firstWhere((s) => s.icao == 'KJKL');
      final site = await nearestPublishingSite(
        jackson.lat,
        jackson.lon,
        publishes: (s) async => s.icao != 'KJKL',
      );
      expect(site.icao, isNot('KJKL'));
    });
  });
}
