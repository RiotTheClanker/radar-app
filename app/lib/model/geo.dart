/// Small geodesy and formatting helpers shared by the controller and the UI.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Beam center height above the radar (meters) at a slant range, using the
/// standard 4/3-earth refraction model.
double beamHeightM(double rangeM, double elevationDeg) {
  const keR = 6371000.0 * 4.0 / 3.0;
  final el = elevationDeg * math.pi / 180.0;
  return math.sqrt(
        rangeM * rangeM + keR * keR + 2 * rangeM * keR * math.sin(el),
      ) -
      keR;
}

/// Great-circle distance (km) and initial bearing (deg) between two points.
(double, double) distanceBearing(LatLng a, LatLng b) {
  const r = 6371.0;
  final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
  final dLat = la2 - la1;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final d = 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  final y = math.sin(dLon) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLon);
  var brg = math.atan2(y, x) * 180 / math.pi;
  if (brg < 0) brg += 360;
  return (d, brg);
}

/// Squared equirectangular distance — plenty for "which site is closest".
double squaredDistance(double lat1, double lon1, double lat2, double lon2) {
  final dy = lat1 - lat2;
  final dx = (lon1 - lon2) * math.cos(lat1 * math.pi / 180.0);
  return dy * dy + dx * dx;
}

/// Compact "how old is this scan" label, e.g. `12m` or `2h`.
String ageLabel(Duration age) {
  if (age.inHours >= 1) return '${age.inHours}h';
  return '${age.inMinutes}m';
}
