/// Active NWS alerts from api.weather.gov (free, no key).
library;

import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// How urgent an alert is, which is also how it gets drawn.
///
/// The NWS does not label this directly, but its event names are strictly
/// conventional: every product ends in Warning, Watch, Advisory or Statement.
enum AlertCategory {
  /// Happening or imminent. Drawn solid, on by default.
  warning,

  /// Conditions are favourable but nothing is happening yet. A watch covers a
  /// large area for hours, so it is drawn faintly and is off by default.
  watch,

  /// Advisories and statements — the least pertinent of the three.
  advisory,
}

extension AlertCategoryLabel on AlertCategory {
  String get label => switch (this) {
        AlertCategory.warning => 'Warnings',
        AlertCategory.watch => 'Watches',
        AlertCategory.advisory => 'Advisories & statements',
      };
}

class WeatherAlert {
  final String id;
  final String event;
  final String headline;
  final String description;
  final String severity;
  final DateTime? expires;
  final List<List<LatLng>> polygons;

  /// Plain-English list of the counties or zones covered. For alerts issued
  /// by zone rather than by polygon this is the only geography there is.
  final String areaDesc;

  WeatherAlert({
    required this.id,
    required this.event,
    required this.headline,
    required this.description,
    required this.severity,
    required this.expires,
    required this.polygons,
    this.areaDesc = '',
  });

  /// Warnings come with a drawn polygon; watches and advisories are issued
  /// for whole counties and usually arrive without one.
  bool get hasPolygon => polygons.isNotEmpty;

  AlertCategory get category => categoryOf(event);

  Color get color => switch (event) {
        'Tornado Warning' => const Color(0xFFFF2A2A),
        'Severe Thunderstorm Warning' => const Color(0xFFFFB300),
        'Flash Flood Warning' => const Color(0xFF00C853),
        'Flood Warning' => const Color(0xFF2E7D32),
        'Special Marine Warning' => const Color(0xFF00B0FF),
        'Snow Squall Warning' => const Color(0xFF80DEEA),
        'Extreme Wind Warning' => const Color(0xFFFF6D00),
        'Tornado Watch' => const Color(0xFFFF8A80),
        'Severe Thunderstorm Watch' => const Color(0xFFFFD54F),
        'Flash Flood Watch' => const Color(0xFF69F0AE),
        _ => switch (categoryOf(event)) {
            AlertCategory.warning => const Color(0xFFB388FF),
            AlertCategory.watch => const Color(0xFF9FA8DA),
            AlertCategory.advisory => const Color(0xFF90A4AE),
          },
      };
}

/// Classify by the last word of the event name, which the NWS keeps strictly
/// conventional across every product it issues.
AlertCategory categoryOf(String event) {
  final e = event.toLowerCase();
  if (e.endsWith('warning')) return AlertCategory.warning;
  if (e.endsWith('watch')) return AlertCategory.watch;
  return AlertCategory.advisory;
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
  return parseAlerts(resp.body);
}

/// Parse an alerts GeoJSON document.
///
/// Alerts without a polygon are kept. They used to be dropped, which silently
/// threw away nearly every watch and advisory: those are issued for lists of
/// counties rather than as drawn polygons, so they have no geometry at all.
/// They cannot go on the map, but they can be listed.
List<WeatherAlert> parseAlerts(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return const [];
  final features = (decoded['features'] as List?) ?? [];

  final alerts = <WeatherAlert>[];
  for (final f in features) {
    if (f is! Map) continue;
    final props = f['properties'];
    if (props is! Map) continue;

    final polygons = <List<LatLng>>[];
    void addRing(List ring) {
      polygons.add([
        for (final c in ring)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ]);
    }

    final geom = f['geometry'];
    if (geom is Map) {
      final coords = geom['coordinates'];
      if (coords is List && coords.isNotEmpty) {
        if (geom['type'] == 'Polygon') {
          addRing(coords[0] as List);
        } else if (geom['type'] == 'MultiPolygon') {
          for (final poly in coords) {
            addRing((poly as List)[0] as List);
          }
        }
      }
    }

    alerts.add(WeatherAlert(
      id: (props['id'] ?? f['id'] ?? '').toString(),
      event: (props['event'] ?? 'Alert').toString(),
      headline: (props['headline'] ?? '').toString(),
      description: (props['description'] ?? '').toString(),
      severity: (props['severity'] ?? '').toString(),
      expires: DateTime.tryParse(props['expires']?.toString() ?? ''),
      polygons: polygons,
      areaDesc: (props['areaDesc'] ?? '').toString(),
    ));
  }
  return alerts;
}
