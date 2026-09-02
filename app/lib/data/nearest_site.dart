/// Choosing which radar to open on.
///
/// Geographically nearest is not the same as usable. The NEXRAD station list
/// includes sites that publish no routine Level 3 products — research radars
/// like KOUN (NSSL, Norman) sit in the list beside the operational KTLX 25 km
/// away — so picking purely by distance can open the app on a radar that
/// never returns anything, and the first-run impression is an app that does
/// not work (#37).
///
/// So the nearest site is *probed* rather than trusted. That costs a listing
/// on a cold start and is self-maintaining: no hand-curated list of
/// non-publishing sites to keep current as the network changes, and it copes
/// with a site that is merely down today as well as one that never publishes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'level3_fetcher.dart';
import 'nexrad_sites.g.dart';

/// Base reflectivity. Every operational WSR-88D publishes it, which is what
/// makes it the right question to ask when the question is "is this radar
/// putting anything out at all".
const _probeProduct = 'N0B';

/// Equirectangular squared distance. Only ever compared against another of
/// the same, and over the few hundred km that separate neighbouring radars,
/// so the projection error costs nothing and a square root is not needed.
double _dist2(double lat1, double lon1, double lat2, double lon2) {
  final dy = lat1 - lat2;
  final dx = (lon1 - lon2) * math.cos(lat1 * math.pi / 180.0);
  return dy * dy + dx * dx;
}

/// Selectable sites ordered by distance from a point, nearest first.
///
/// TDWR sites are left out: their products are a later phase, and offering
/// one as a startup default would open on a radar the app cannot draw.
List<NexradSite> sitesByDistance(double lat, double lon) {
  final sites = [for (final s in nexradSites) if (!s.isTdwr) s];
  sites.sort((a, b) => _dist2(lat, lon, a.lat, a.lon)
      .compareTo(_dist2(lat, lon, b.lat, b.lon)));
  return sites;
}

/// The nearest site, geometrically. What the app used to open on.
///
/// Still the honest answer when nothing can be reached — better to open on a
/// plausible radar and show its error than to open on nothing.
NexradSite nearestSite(double lat, double lon) => sitesByDistance(lat, lon).first;

/// Whether a site has published base reflectivity recently.
Future<bool> _publishesLevel3(NexradSite site) async {
  try {
    final keys = await listRecentKeys(site.shortId, _probeProduct, count: 1)
        .timeout(const Duration(seconds: 6));
    return keys.isNotEmpty;
  } catch (_) {
    // A probe that failed is not evidence the radar is silent — it is just as
    // likely to be us. Treated as "unknown", which the caller reads as "keep
    // looking", and the geometric nearest is still there as the last word.
    return false;
  }
}

/// The nearest site that is actually publishing.
///
/// Probes candidates outward from [lat]/[lon] and returns the first that has
/// recent data. Gives up after [maxProbes] and returns the geometric nearest,
/// so a user with no network still opens on the right radar and sees the
/// pane's own error rather than a silently different site.
///
/// Four probes because non-publishing sites cluster. Norman is the worked
/// example and needs three: KOUN (NSSL) and KCRI (the ROC's redundant test
/// RDA) are both within a kilometre of each other and of the user, and the
/// operational KTLX is only third. Three would have cleared it with nothing
/// to spare; a fourth is one listing in a case that is already rare, and the
/// alternative is falling back to a radar that publishes nothing.
///
/// [budget] caps the whole search, not each probe. Startup waits on this
/// before the panes may load, so an unreachable network must not be able to
/// hold the app on a blank screen for as long as it takes every probe in turn
/// to time out. When the budget runs out the geometric nearest is used, which
/// is exactly what the app did before any of this existed.
///
/// [publishes] is injectable so this can be tested without the network.
Future<NexradSite> nearestPublishingSite(
  double lat,
  double lon, {
  int maxProbes = 4,
  Duration budget = const Duration(seconds: 8),
  Future<bool> Function(NexradSite)? publishes,
}) async {
  final ranked = sitesByDistance(lat, lon);
  if (ranked.isEmpty) return nexradSites.first;
  final probe = publishes ?? _publishesLevel3;

  Future<NexradSite> search() async {
    final limit = math.min(maxProbes, ranked.length);
    for (var i = 0; i < limit; i++) {
      if (await probe(ranked[i])) return ranked[i];
    }
    return ranked.first;
  }

  try {
    return await search().timeout(budget);
  } on TimeoutException {
    return ranked.first;
  }
}
