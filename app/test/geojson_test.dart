/// GeoJSON overlays: the coordinate order, the styling keys, and that one
/// bad feature does not cost the file.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/geojson.dart';

const _doc = '''
{"type": "FeatureCollection", "features": [
  {"type": "Feature",
   "properties": {"name": "County", "stroke": "#ff0000", "fill": "#00ff00",
                  "fill-opacity": 0.25, "stroke-width": 3},
   "geometry": {"type": "Polygon", "coordinates": [
     [[-98, 35], [-97, 35], [-97, 36], [-98, 36], [-98, 35]],
     [[-97.6, 35.4], [-97.4, 35.4], [-97.4, 35.6], [-97.6, 35.4]]]}},
  {"type": "Feature", "properties": {"title": "I-35"},
   "geometry": {"type": "MultiLineString", "coordinates": [
     [[-97.5, 35], [-97.5, 36]], [[-97.4, 35], [-97.4, 36]]]}},
  {"type": "Feature", "properties": {"name": "Tower", "marker-color": "#00f"},
   "geometry": {"type": "Point", "coordinates": [-97.5, 35.5]}},
  {"type": "Feature", "properties": {},
   "geometry": {"type": "Point", "coordinates": ["bad"]}},
  {"type": "Feature", "properties": null,
   "geometry": {"type": "GeometryCollection", "geometries": [
     {"type": "Point", "coordinates": [-96, 34]}]}}
]}
''';

void main() {
  late GeoShapes g;
  setUp(() => g = parseGeoJson(_doc));

  test('longitude comes first in GeoJSON', () {
    final p = g.points.first.pos;
    expect(p.latitude, 35.5);
    expect(p.longitude, -97.5);
  });

  test('polygons keep their holes', () {
    final poly = g.polygons.single;
    expect(poly.outer, hasLength(5));
    expect(poly.holes.single, hasLength(4));
  });

  test('simplestyle keys style the feature', () {
    final s = g.polygons.single.style;
    expect(s.stroke, const Color(0xFFFF0000));
    expect(s.fill!.a, closeTo(0.25, 0.01));
    expect(s.width, 3);
    expect(s.label, 'County');
    expect(g.points.first.style.stroke, const Color(0xFF0000FF),
        reason: 'marker-color colours a point');
  });

  test('multi-geometries split, collections recurse', () {
    expect(g.lines, hasLength(2));
    expect(g.lines.first.style.label, 'I-35', reason: 'title is a label too');
    expect(g.points.map((p) => p.pos.longitude), [-97.5, -96]);
  });

  test('a malformed feature is skipped, the rest kept', () {
    expect(g.count, 1 + 2 + 2);
  });

  test('a bare geometry is a document too', () {
    final one = parseGeoJson('{"type": "Point", "coordinates": [1, 2]}');
    expect(one.points.single.pos.latitude, 2);
  });

  test('something that is not GeoJSON is refused', () {
    expect(() => parseGeoJson('[1, 2]'), throwsFormatException);
    expect(() => parseGeoJson('{"a": 1}'), throwsFormatException);
  });

  group('colours', () {
    test('the forms addon files use', () {
      expect(parseColor('#abc'), const Color(0xFFAABBCC));
      expect(parseColor('#AABBCC'), const Color(0xFFAABBCC));
      expect(parseColor('AABBCC'), const Color(0xFFAABBCC));
      expect(parseColor('#AABBCC80'), const Color(0x80AABBCC),
          reason: 'alpha last, as CSS writes it');
    });

    test('anything else is null', () {
      expect(parseColor('red'), isNull);
      expect(parseColor('#12345'), isNull);
      expect(parseColor(3), isNull);
    });
  });
}
