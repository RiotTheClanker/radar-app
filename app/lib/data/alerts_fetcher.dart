/// Active NWS watches/warnings from api.weather.gov (free, no key).
library;

import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class WeatherAlert {
  final String id;
  final String event;
  final String headline;
  final String description;
  final String severity;
  final DateTime? expires;
  final List<List<LatLng>> polygons;

  WeatherAlert({
    required this.id,
    required this.event,
    required this.headline,
    required this.description,
    required this.severity,
    required this.expires,
    required this.polygons,
  });

  Color get color => switch (event) {
        'Tornado Warning' => const Color(0xFFFF2A2A),
        'Severe Thunderstorm Warning' => const Color(0xFFFFB300),
        'Flash Flood Warning' => const Color(0xFF00C853),
        'Flood Warning' => const Color(0xFF2E7D32),
        'Special Marine Warning' => const Color(0xFF00B0FF),
        'Snow Squall Warning' => const Color(0xFF80DEEA),
        'Extreme Wind Warning' => const Color(0xFFFF6D00),
        _ => const Color(0xFFB388FF),
      };
}

/// NWS asks for a descriptive User-Agent; requests without one get blocked.
const _headers = {
  'User-Agent': 'radar_app-dev (open source radar app)',
  'Accept': 'application/geo+json',
};

Future<List<WeatherAlert>> fetchActiveAlerts() async {
  final uri = Uri.parse(
    'https://api.weather.gov/alerts/active?status=actual',
  );
  final resp = await http.get(uri, headers: _headers);
  if (resp.statusCode != 200) {
    throw Exception('alerts fetch failed: HTTP ${resp.statusCode}');
  }
  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final features = (body['features'] as List?) ?? [];

  final alerts = <WeatherAlert>[];
  for (final f in features) {
    final geom = f['geometry'];
    if (geom == null) continue; // county-based alerts without polygons
    final props = f['properties'] as Map<String, dynamic>;

    final polygons = <List<LatLng>>[];
    void addRing(List ring) {
      polygons.add([
        for (final c in ring) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ]);
    }

    final type = geom['type'];
    final coords = geom['coordinates'] as List;
    if (type == 'Polygon') {
      addRing(coords[0] as List);
    } else if (type == 'MultiPolygon') {
      for (final poly in coords) {
        addRing((poly as List)[0] as List);
      }
    } else {
      continue;
    }

    alerts.add(WeatherAlert(
      id: (props['id'] ?? f['id'] ?? '').toString(),
      event: (props['event'] ?? 'Alert').toString(),
      headline: (props['headline'] ?? '').toString(),
      description: (props['description'] ?? '').toString(),
      severity: (props['severity'] ?? '').toString(),
      expires: DateTime.tryParse(props['expires']?.toString() ?? ''),
      polygons: polygons,
    ));
  }
  return alerts;
}
