/// GeoJSON, read into shapes the map can draw.
///
/// For addon overlays: county roads, a fire district's boundary, a chase
/// team's positions, whatever someone has as GeoJSON. Plain shapes out —
/// rings, lines, points — so the map layer never sees JSON and this never
/// sees a widget.
///
/// Per-feature styling follows Mapbox's simplestyle-spec (`stroke`, `fill`,
/// `stroke-width`, `fill-opacity`, `marker-color`), which is what geojson.io
/// and most exporters already write. Anything the feature does not say comes
/// from the overlay's own defaults.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:latlong2/latlong.dart';

class GeoPolygon {
  const GeoPolygon(this.outer, this.holes, this.style);
  final List<LatLng> outer;
  final List<List<LatLng>> holes;
  final GeoStyle style;
}

class GeoLine {
  const GeoLine(this.points, this.style);
  final List<LatLng> points;
  final GeoStyle style;
}

class GeoPoint {
  const GeoPoint(this.pos, this.style, this.properties);
  final LatLng pos;
  final GeoStyle style;

  /// Everything the feature carried, for the tap readout.
  final Map<String, Object?> properties;
}

/// What a feature asked to look like. Nulls mean "use the overlay's".
class GeoStyle {
  const GeoStyle({this.stroke, this.fill, this.width, this.label});
  final Color? stroke;
  final Color? fill;
  final double? width;
  final String? label;
}

class GeoShapes {
  const GeoShapes({
    this.polygons = const [],
    this.lines = const [],
    this.points = const [],
  });
  final List<GeoPolygon> polygons;
  final List<GeoLine> lines;
  final List<GeoPoint> points;

  int get count => polygons.length + lines.length + points.length;

  static const empty = GeoShapes();
}

/// Parse a GeoJSON document — a FeatureCollection, a single Feature, or a
/// bare geometry. [labelKey] names the property to label features with;
/// without it, `name` then `title`.
///
/// Throws a [FormatException] for something that is not GeoJSON at all.
/// A single malformed feature is skipped rather than failing the file: one
/// bad vertex in a county layer should not cost the other hundred counties.
GeoShapes parseGeoJson(String text, {String? labelKey}) {
  final doc = jsonDecode(text);
  if (doc is! Map) throw const FormatException('not a GeoJSON object');
  final polys = <GeoPolygon>[];
  final lines = <GeoLine>[];
  final points = <GeoPoint>[];

  void geometry(Object? g, Map<String, Object?> props) {
    if (g is! Map) return;
    final style = _style(props, labelKey);
    final coords = g['coordinates'];
    try {
      switch (g['type']) {
        case 'Point':
          points.add(GeoPoint(_pt(coords), style, props));
        case 'MultiPoint':
          for (final c in coords as List) {
            points.add(GeoPoint(_pt(c), style, props));
          }
        case 'LineString':
          lines.add(GeoLine(_line(coords), style));
        case 'MultiLineString':
          for (final c in coords as List) {
            lines.add(GeoLine(_line(c), style));
          }
        case 'Polygon':
          polys.add(_poly(coords, style));
        case 'MultiPolygon':
          for (final c in coords as List) {
            polys.add(_poly(c, style));
          }
        case 'GeometryCollection':
          for (final sub in (g['geometries'] as List? ?? const [])) {
            geometry(sub, props);
          }
      }
    } catch (_) {
      // Malformed coordinates in one feature; the rest still draw.
    }
  }

  void feature(Object? f) {
    if (f is! Map) return;
    final props = <String, Object?>{
      ...?(f['properties'] as Map?)?.cast<String, Object?>(),
    };
    geometry(f['geometry'], props);
  }

  switch (doc['type']) {
    case 'FeatureCollection':
      for (final f in (doc['features'] as List? ?? const [])) {
        feature(f);
      }
    case 'Feature':
      feature(doc);
    case null:
      throw const FormatException('no GeoJSON "type"');
    default:
      geometry(doc, const {});
  }
  return GeoShapes(polygons: polys, lines: lines, points: points);
}

/// GeoJSON is longitude first. Getting that backwards puts Oklahoma in
/// Antarctica, so it is done in exactly one place.
LatLng _pt(Object? c) {
  final l = c as List;
  final lat = (l[1] as num).toDouble();
  final lon = (l[0] as num).toDouble();
  if (lat.abs() > 90 || lon.abs() > 540) {
    throw const FormatException('coordinate out of range');
  }
  return LatLng(lat, lon);
}

List<LatLng> _line(Object? c) => [for (final p in c as List) _pt(p)];

GeoPolygon _poly(Object? c, GeoStyle style) {
  final rings = [for (final r in c as List) _line(r)];
  if (rings.isEmpty) throw const FormatException('empty polygon');
  return GeoPolygon(rings.first, rings.skip(1).toList(), style);
}

GeoStyle _style(Map<String, Object?> p, String? labelKey) {
  final strokeOpacity = _num(p['stroke-opacity']);
  final fillOpacity = _num(p['fill-opacity']);
  var stroke = parseColor(p['stroke']) ?? parseColor(p['marker-color']);
  var fill = parseColor(p['fill']);
  if (stroke != null && strokeOpacity != null) {
    stroke = stroke.withValues(alpha: strokeOpacity.clamp(0.0, 1.0));
  }
  if (fill != null && fillOpacity != null) {
    fill = fill.withValues(alpha: fillOpacity.clamp(0.0, 1.0));
  }
  final label = labelKey != null ? p[labelKey] : (p['name'] ?? p['title']);
  return GeoStyle(
    stroke: stroke,
    fill: fill,
    width: _num(p['stroke-width']),
    label: label?.toString(),
  );
}

double? _num(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// A colour as addon files write them: `#RGB`, `#RRGGBB`, or `#RRGGBBAA`
/// (alpha last, the way CSS has it — not Flutter's `0xAARRGGBB`). Null for
/// anything else.
Color? parseColor(Object? v) {
  if (v is! String) return null;
  var h = v.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = '${h}ff';
  if (h.length != 8) return null;
  final n = int.tryParse(h, radix: 16);
  if (n == null) return null;
  final rgb = n >> 8;
  final a = n & 0xff;
  return Color((a << 24) | rgb);
}

/// [shapes] with detail finer than [tolerance] degrees taken out: rings
/// smaller than a few tolerances dropped, and every remaining line and ring
/// thinned with Douglas–Peucker.
///
/// For live feeds that were drawn for a GIS rather than a map on a phone.
/// US wildfire perimeters are the case that forced it: eighty-odd fires came
/// as over four thousand rings, nearly all of them unburned islands a few
/// metres across, and the map re-triangulated every one on every repaint —
/// the whole app slowed down while the layer was on.
GeoShapes simplifyShapes(GeoShapes shapes, double tolerance) {
  if (tolerance <= 0) return shapes;
  final minSpan = tolerance * 3;
  final polys = <GeoPolygon>[];
  for (final p in shapes.polygons) {
    if (_span(p.outer) < minSpan) continue;
    final outer = _thinRing(p.outer, tolerance);
    if (outer == null) continue;
    polys.add(GeoPolygon(
      outer,
      [
        for (final h in p.holes)
          if (_span(h) >= minSpan) ?_thinRing(h, tolerance),
      ],
      p.style,
    ));
  }
  return GeoShapes(
    polygons: polys,
    lines: [
      for (final l in shapes.lines)
        if (l.points.length >= 2)
          GeoLine(_douglasPeucker(l.points, tolerance), l.style),
    ],
    points: shapes.points,
  );
}

/// The larger side of a ring's bounding box, in degrees.
double _span(List<LatLng> pts) {
  if (pts.isEmpty) return 0;
  var minLat = pts.first.latitude, maxLat = minLat;
  var minLon = pts.first.longitude, maxLon = minLon;
  for (final p in pts) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLon) minLon = p.longitude;
    if (p.longitude > maxLon) maxLon = p.longitude;
  }
  return math.max(maxLat - minLat, maxLon - minLon);
}

/// A ring thinned, or null if too little of it is left to enclose anything.
List<LatLng>? _thinRing(List<LatLng> ring, double tolerance) {
  final out = _douglasPeucker(ring, tolerance);
  return out.length < 4 ? null : out;
}

List<LatLng> _douglasPeucker(List<LatLng> pts, double tolerance) {
  if (pts.length < 3) return pts;
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final t2 = tolerance * tolerance;
  // Iterative, so a 10 000-point coastline cannot overflow the stack.
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var worst = -1.0;
    var at = -1;
    for (var i = a + 1; i < b; i++) {
      final d = _segDist2(pts[i], pts[a], pts[b]);
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at >= 0 && worst > t2) {
      keep[at] = true;
      stack
        ..add((a, at))
        ..add((at, b));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

/// Squared distance from [p] to segment [a]–[b], in plain degrees. Over the
/// few hundred metres a tolerance spans the projection hardly matters.
double _segDist2(LatLng p, LatLng a, LatLng b) {
  final ax = a.longitude, ay = a.latitude;
  final dx = b.longitude - ax, dy = b.latitude - ay;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0
      ? 0.0
      : ((p.longitude - ax) * dx + (p.latitude - ay) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final ex = ax + t * dx - p.longitude, ey = ay + t * dy - p.latitude;
  return ex * ex + ey * ey;
}
