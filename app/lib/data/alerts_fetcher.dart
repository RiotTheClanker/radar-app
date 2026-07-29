/// Active NWS alerts from api.weather.gov (free, no key).
library;

import 'dart:convert';
import 'dart:math' as math;
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

  /// Plain-English list of the counties or zones covered.
  final String areaDesc;

  /// API URLs of the zones this alert covers. County-issued alerts arrive
  /// with no drawn shape at all; these are what their outline has to be
  /// built from.
  final List<String> zoneUrls;

  WeatherAlert({
    required this.id,
    required this.event,
    required this.headline,
    required this.description,
    required this.severity,
    required this.expires,
    required this.polygons,
    this.areaDesc = '',
    this.zoneUrls = const [],
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

/// Fetch every active alert.
///
/// The API caps a page at 500 features and nationally there are often more
/// than that, so a single request silently truncates the set — which is how
/// a whole category can appear to be missing. Follow the pagination cursor.
Future<List<WeatherAlert>> fetchActiveAlerts({int maxPages = 6}) async {
  var url = 'https://api.weather.gov/alerts/active?status=actual&limit=500';
  final all = <WeatherAlert>[];
  final seen = <String>{};

  for (var page = 0; page < maxPages; page++) {
    final resp = await http.get(Uri.parse(url), headers: _headers);
    if (resp.statusCode != 200) {
      if (page == 0) {
        throw Exception('alerts fetch failed: HTTP ${resp.statusCode}');
      }
      break; // keep what we already have
    }
    for (final a in parseAlerts(resp.body)) {
      if (seen.add(a.id)) all.add(a);
    }
    final next = nextPageUrl(resp.body);
    if (next == null || next == url) break;
    url = next;
  }
  return all;
}

/// The cursor for the next page, or null at the end.
String? nextPageUrl(String body) {
  // The body is not always JSON — a gateway error page will arrive here too,
  // and throwing would lose the pages already fetched.
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final pagination = decoded['pagination'];
  if (pagination is! Map) return null;
  final next = pagination['next'];
  return (next is String && next.isNotEmpty) ? next : null;
}

/// Zone outlines, keyed by API URL. Zone geography does not change, so this
/// only ever grows and a refresh costs nothing for zones already seen.
final Map<String, List<List<LatLng>>> _zoneCache = {};

/// Give county-issued alerts an outline to draw.
///
/// A watch covers dozens of counties and carries no polygon of its own, so
/// without this it can only ever be listed, never shown on the map. Zones are
/// fetched once each and cached; [maxFetches] bounds a cold start, and
/// anything that fails just leaves that alert list-only.
Future<void> resolveZoneOutlines(
  List<WeatherAlert> alerts, {
  int maxFetches = 240,
}) async {
  final wanted = <String>{};
  for (final a in alerts) {
    if (a.hasPolygon) continue;
    for (final z in a.zoneUrls) {
      if (!_zoneCache.containsKey(z)) wanted.add(z);
    }
  }

  for (final batch in _chunks(wanted.take(maxFetches).toList(), 12)) {
    await Future.wait([for (final z in batch) _fetchZone(z)]);
  }

  for (final a in alerts) {
    if (a.hasPolygon) continue;
    for (final z in a.zoneUrls) {
      final rings = _zoneCache[z];
      if (rings != null) a.polygons.addAll(rings);
    }
  }
}

Iterable<List<T>> _chunks<T>(List<T> list, int size) sync* {
  for (var i = 0; i < list.length; i += size) {
    yield list.sublist(i, math.min(i + size, list.length));
  }
}

Future<void> _fetchZone(String url) async {
  try {
    final resp = await http
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      _zoneCache[url] = const []; // remember the miss, do not retry forever
      return;
    }
    _zoneCache[url] = ringsOfFeature(jsonDecode(resp.body));
  } catch (_) {
    _zoneCache[url] = const [];
  }
}

/// Outer rings of a GeoJSON Feature's Polygon or MultiPolygon geometry.
List<List<LatLng>> ringsOfFeature(Object? decoded) {
  if (decoded is! Map) return const [];
  final geom = decoded['geometry'];
  if (geom is! Map) return const [];
  final coords = geom['coordinates'];
  if (coords is! List || coords.isEmpty) return const [];

  List<LatLng> ring(List r) => [
        for (final c in r)
          if (c is List && c.length >= 2)
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];

  if (geom['type'] == 'Polygon') {
    return [ring(coords[0] as List)];
  }
  if (geom['type'] == 'MultiPolygon') {
    return [for (final p in coords) ring((p as List)[0] as List)];
  }
  return const [];
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
      zoneUrls: [
        for (final z in (props['affectedZones'] as List?) ?? const [])
          z.toString(),
      ],
    ));
  }
  return alerts;
}
