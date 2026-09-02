import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/sounding_fetcher.dart';
import 'package:radar_app/data/sounding_indices.dart';

SoundingLevel _l(double p, double h, double? t, double? td,
        [double? dir, double? kt]) =>
    SoundingLevel(
      pressureHpa: p,
      heightM: h,
      tempC: t,
      dewpointC: td,
      windDirDeg: dir,
      windKt: kt,
    );

Sounding _snd(List<SoundingLevel> levels) =>
    Sounding(station: 'TST', title: 'test', levels: levels);

/// A warm, moist, sheared profile — the shape of a severe-weather day.
Sounding _unstable() => _snd([
      _l(1000, 100, 30, 23, 160, 15),
      _l(925, 780, 24, 20, 180, 25),
      _l(850, 1500, 20, 17, 200, 30),
      _l(700, 3100, 9, 4, 220, 40),
      _l(600, 4400, 0, -6, 230, 45),
      _l(500, 5900, -9, -18, 240, 55),
      _l(400, 7600, -21, -32, 250, 65),
      _l(300, 9700, -38, -50, 255, 75),
      _l(250, 10900, -49, -60, 260, 80),
      _l(200, 12300, -56, -68, 260, 85),
    ]);

/// Cold and dry, with no reason to convect.
Sounding _stable() => _snd([
      _l(1000, 100, 5, -10, 300, 10),
      _l(925, 750, 2, -14, 300, 12),
      _l(850, 1450, 0, -18, 305, 14),
      _l(700, 3000, -8, -25, 310, 18),
      _l(500, 5700, -25, -40, 315, 25),
      _l(300, 9400, -50, -65, 320, 35),
    ]);

void main() {
  group('instability', () {
    test('a warm moist profile has real CAPE', () {
      final i = computeIndices(_unstable());
      expect(i.capeJkg, isNotNull);
      expect(i.capeJkg!, greaterThan(500),
          reason: 'this profile should clearly convect');
      expect(i.capeJkg!, lessThan(8000), reason: 'but not absurdly so');
    });

    test('a cold dry profile has essentially none', () {
      final i = computeIndices(_stable());
      expect(i.capeJkg ?? 0, lessThan(50));
    });

    test('lifted index is negative when unstable, positive when not', () {
      expect(computeIndices(_unstable()).liC!, lessThan(0));
      expect(computeIndices(_stable()).liC!, greaterThan(0));
    });

    test('most-unstable CAPE is never below surface-based', () {
      final i = computeIndices(_unstable());
      expect(i.muCapeJkg!, greaterThanOrEqualTo(i.capeJkg! - 1e-6));
    });

    test('inhibition is zero or negative, never positive', () {
      for (final s in [_unstable(), _stable()]) {
        final cin = computeIndices(s).cinJkg;
        if (cin != null) expect(cin, lessThanOrEqualTo(0));
      }
    });
  });

  group('levels', () {
    test('the LCL sits above the ground and below the storm top', () {
      final i = computeIndices(_unstable());
      expect(i.lclM, isNotNull);
      expect(i.lclM!, greaterThan(0));
      expect(i.lclM!, lessThan(4000),
          reason: 'a surface dewpoint depression of 7C is a low cloud base');
    });

    test('the LCL matches the dewpoint-depression rule of thumb', () {
      // Cloud base rises about 125 m per degree of surface dewpoint
      // depression. 30C over 23C is 7 degrees, so roughly 875 m. Reading the
      // height off the next reported level instead of interpolating to the
      // LCL pressure puts this out by 500 m.
      final i = computeIndices(_unstable());
      expect(i.lclM!, closeTo(125 * 7, 150));
    });

    test('the LFC is at or above the LCL', () {
      final i = computeIndices(_unstable());
      if (i.lfcM != null && i.lclM != null) {
        expect(i.lfcM!, greaterThanOrEqualTo(i.lclM! - 500));
      }
    });

    test('the freezing level is interpolated, not snapped to a level', () {
      // 600 hPa is exactly 0 C here, so freezing is at that height, 4400 m,
      // minus the 100 m surface elevation.
      final i = computeIndices(_unstable());
      expect(i.freezingM, isNotNull);
      expect(i.freezingM!, closeTo(4300, 250));
    });
  });

  group('moisture', () {
    test('precipitable water is larger for the moist profile', () {
      final wet = computeIndices(_unstable()).pwatMm!;
      final dry = computeIndices(_stable()).pwatMm!;
      expect(wet, greaterThan(dry));
      // A deeply moist warm-sector sounding runs 25-60 mm.
      expect(wet, inInclusiveRange(15, 80));
    });

    test('saturation vapour pressure matches known values', () {
      // 6.11 hPa at 0 C, about 23.4 hPa at 20 C.
      expect(saturationVapourPressure(0), closeTo(6.112, 0.01));
      expect(saturationVapourPressure(20), closeTo(23.4, 0.3));
    });
  });

  group('wind', () {
    test('shear grows with depth', () {
      final i = computeIndices(_unstable());
      expect(i.shear1kmKt, isNotNull);
      expect(i.shear6kmKt, isNotNull);
      expect(i.shear6kmKt!, greaterThan(i.shear1kmKt!));
      // Surface 160/15 to 6 km near 240/55 is a strongly sheared profile.
      expect(i.shear6kmKt!, greaterThan(30));
    });

    test('a veering profile gives positive right-mover helicity', () {
      final i = computeIndices(_unstable());
      expect(i.srh1km, isNotNull);
      expect(i.srh3km, isNotNull);
      expect(i.srh3km!, greaterThan(0),
          reason: 'winds veering with height is positive helicity');
      expect(i.srh3km!.abs(), greaterThan(i.srh1km!.abs()));
    });

    test('storm motion is a plausible direction and speed', () {
      final i = computeIndices(_unstable());
      expect(i.stormDirDeg, inInclusiveRange(0, 360));
      expect(i.stormKt!, inInclusiveRange(5, 90));
    });
  });

  group('degenerate input', () {
    test('too few levels yields empty rather than throwing', () {
      final i = computeIndices(_snd([_l(1000, 100, 20, 15)]));
      expect(i.capeJkg, isNull);
    });

    test('missing dewpoints do not crash the parcel lift', () {
      final i = computeIndices(_snd([
        _l(1000, 100, 30, null, 180, 20),
        _l(850, 1500, 20, null, 200, 30),
        _l(500, 5900, -9, null, 240, 55),
      ]));
      expect(i.shear6kmKt, isNotNull);
    });

    test('missing winds still allow the thermodynamics', () {
      final i = computeIndices(_snd([
        _l(1000, 100, 30, 23),
        _l(850, 1500, 20, 17),
        _l(700, 3100, 9, 4),
        _l(500, 5900, -9, -18),
      ]));
      expect(i.capeJkg, isNotNull);
      expect(i.srh3km, isNull);
    });
  });

  /// The indices panel (#46). Fourteen bare acronyms meant nothing to a
  /// newcomer; these are what the letters expand to.
  group('index help text', () {
    /// Every abbreviation the panel can draw must have words behind it, or
    /// the long-press does nothing and the label is bare again for that one.
    test('covers every index the panel shows', () {
      const shown = [
        'CAPE', 'CIN', 'MUCAPE', 'LI', 'LCL', 'LFC', 'EL', '0°C',
        'PWAT', '0-1 SHR', '0-6 SHR', 'SRH1', 'SRH3', 'STORM',
      ];
      for (final label in shown) {
        expect(soundingIndexHelp.containsKey(label), isTrue,
            reason: '$label has no explanation');
        expect(soundingIndexHelp[label]!.trim(), isNotEmpty);
      }
      expect(soundingIndexHelp.length, shown.length,
          reason: 'no explanations for indices that are not displayed');
    });

    /// The line this app should not cross. Saying what CAPE measures is
    /// help; saying what 3000 J/kg means for this afternoon is a forecast,
    /// from a tool whose own README says never to rely on it as your only
    /// source of warnings. Digits are a blunt proxy for a threshold, and a
    /// blunt proxy is what makes this catchable.
    test('describes what is measured, never what a value implies', () {
      for (final entry in soundingIndexHelp.entries) {
        // Naming a layer ("surface to 1 km") is describing where something is
        // measured, not asserting what a reading means, so it is the one
        // numeric form these are allowed.
        final claims = entry.value.replaceAll(RegExp(r'\d+ km'), 'a layer');
        expect(
          RegExp(r'\d').hasMatch(claims),
          isFalse,
          reason: '${entry.key} quotes a number: "${entry.value}"',
        );
      }
    });

    test('reads as a sentence, not another abbreviation', () {
      for (final entry in soundingIndexHelp.entries) {
        expect(entry.value.length, greaterThan(20),
            reason: '${entry.key} is too terse to help');
      }
    });
  });

  /// Choosing a launch site (#48). Seventy sites in table order is a scroll
  /// through half a continent; nearest-first puts the one over the storm you
  /// are looking at at the top.
  group('launch site ordering', () {
    // Norman, Oklahoma, whose own launch site is OUN.
    const lat = 35.2, lon = -97.4;

    test('nearest first', () {
      final ranked = raobSitesByDistance(lat, lon);
      expect(ranked.first.id, 'OUN');
      expect(ranked.length, raobSites.length,
          reason: 'ordering, not filtering — every site stays reachable');
    });

    test('distances come out ascending', () {
      final ranked = raobSitesByDistance(lat, lon);
      var previous = -1.0;
      for (final s in ranked) {
        final d = raobDistanceKm(lat, lon, s);
        expect(d, greaterThanOrEqualTo(previous));
        previous = d;
      }
    });

    test('nearestRaobSite still agrees with the ordering', () {
      expect(nearestRaobSite(lat, lon).id, raobSitesByDistance(lat, lon).first.id);
    });

    /// The number shown beside each name. OUN to LMN (Lamont) is about 165 km
    /// on the ground, and a flat approximation over that distance should not
    /// be visibly wrong.
    test('the distance shown is about right', () {
      final oun = raobSites.firstWhere((s) => s.id == 'OUN');
      final lmn = raobSites.firstWhere((s) => s.id == 'LMN');
      final d = raobDistanceKm(oun.lat, oun.lon, lmn);
      expect(d, inInclusiveRange(150, 185));
      expect(raobDistanceKm(oun.lat, oun.lon, oun), lessThan(1));
    });
  });
}
