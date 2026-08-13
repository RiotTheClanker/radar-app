/// Spherical geometry the radar views need.
///
/// Pulled out of the pane widget because it is arithmetic, not interface:
/// a range ring either passes through the point it was built for or it does
/// not, and that is worth asserting directly rather than inferring from a
/// screenshot.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Mean earth radius, km. The same figure the sampling code uses, so a
/// distance drawn on the map and a distance reported in the readout agree.
const earthRadiusKm = 6371.0;

/// Great-circle distance (km) and initial bearing (deg) from [a] to [b].
(double, double) distanceBearing(LatLng a, LatLng b) {
  final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
  final dLat = la2 - la1;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final d = 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h)));
  final y = math.sin(dLon) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLon);
  var brg = math.atan2(y, x) * 180 / math.pi;
  if (brg < 0) brg += 360;
  return (d, brg);
}

/// A closed ring of points exactly [km] from [centre], every bearing.
///
/// The alternative — flutter_map's `CircleMarker` with `useRadiusInMeter` —
/// converts the radius to pixels once and then paints a plain screen circle.
/// Web Mercator's scale changes with latitude, so a constant-distance ring
/// is not a circle on screen; it is egg-shaped, and increasingly so the
/// larger the radius. That is why a range ring drifted off the crosshair the
/// further out you aimed.
List<LatLng> geodesicRing(LatLng centre, double km, {int points = 240}) {
  final d = km / earthRadiusKm;
  final lat1 = centre.latitude * math.pi / 180.0;
  final lon1 = centre.longitude * math.pi / 180.0;
  final sinLat1 = math.sin(lat1), cosLat1 = math.cos(lat1);
  final sinD = math.sin(d), cosD = math.cos(d);

  final ring = <LatLng>[];
  for (var i = 0; i <= points; i++) {
    final brg = 2 * math.pi * i / points;
    final lat2 = math.asin(sinLat1 * cosD + cosLat1 * sinD * math.cos(brg));
    final lon2 = lon1 +
        math.atan2(
          math.sin(brg) * sinD * cosLat1,
          cosD - sinLat1 * math.sin(lat2),
        );
    var lonDeg = lon2 * 180.0 / math.pi;
    // Keep the ring continuous across the antimeridian — a jump from +179 to
    // -179 would be drawn as a line straight back across the map. Matters
    // for the Alaskan and Pacific sites.
    final delta = lonDeg - centre.longitude;
    if (delta > 180) lonDeg -= 360;
    if (delta < -180) lonDeg += 360;
    ring.add(LatLng(lat2 * 180.0 / math.pi, lonDeg));
  }
  return ring;
}

/// Beam centre height above the radar (metres) at a slant range, using the
/// standard 4/3-earth refraction model.
double beamHeightM(double rangeM, double elevationDeg) {
  const keR = earthRadiusKm * 1000.0 * 4.0 / 3.0;
  final el = elevationDeg * math.pi / 180.0;
  return math.sqrt(
        rangeM * rangeM + keR * keR + 2 * rangeM * keR * math.sin(el),
      ) -
      keR;
}
