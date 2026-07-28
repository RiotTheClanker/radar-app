/// Device location. Desktop has no GPS, so fall back to IP geolocation
/// (city-level accuracy — plenty for picking the nearest radar site).
/// On Android this will be replaced by real GPS via a location plugin.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

Future<LatLng?> locate() async {
  try {
    final resp = await http
        .get(Uri.parse('https://ipapi.co/json/'))
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) return null;
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final lat = (j['latitude'] as num?)?.toDouble();
    final lon = (j['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  } catch (_) {
    return null;
  }
}
