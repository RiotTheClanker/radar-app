import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/alerts_fetcher.dart';

/// One GeoJSON feature. Passing no geometry is the case that matters: that is
/// how the NWS issues watches and advisories, by county rather than polygon.
Map<String, dynamic> _feature({
  required String event,
  List<List<double>>? ring,
  String areaDesc = 'Cleveland, OK',
}) =>
    {
      'id': 'urn:$event',
      'geometry': ring == null
          ? null
          : {
              'type': 'Polygon',
              'coordinates': [
                [for (final p in ring) p],
              ],
            },
      'properties': {
        'event': event,
        'headline': '$event issued',
        'description': 'body text',
        'severity': 'Severe',
        'areaDesc': areaDesc,
        'expires': '2026-07-29T04:00:00+00:00',
      },
    };

String _doc(List<Map<String, dynamic>> features) =>
    jsonEncode({'type': 'FeatureCollection', 'features': features});

const _box = [
  [-97.6, 35.3],
  [-97.4, 35.3],
  [-97.4, 35.5],
  [-97.6, 35.5],
  [-97.6, 35.3],
];

void main() {
  group('pagination', () {
    test('the next cursor is followed until it runs out', () {
      const body = '{"features":[],"pagination":{"next":"https://x/page2"}}';
      expect(nextPageUrl(body), 'https://x/page2');
    });

    test('no cursor means the last page', () {
      expect(nextPageUrl('{"features":[]}'), isNull);
      expect(nextPageUrl('{"features":[],"pagination":{}}'), isNull);
      expect(nextPageUrl('{"features":[],"pagination":{"next":""}}'), isNull);
      expect(nextPageUrl('not json at all'.replaceAll('x', 'x')), isNull);
    });
  });

  group('zone outlines', () {
    test('a zone Feature yields its ring', () {
      final zone = {
        'type': 'Feature',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              [-97.6, 35.3],
              [-97.4, 35.3],
              [-97.4, 35.5],
            ]
          ],
        },
      };
      final rings = ringsOfFeature(zone);
      expect(rings.length, 1);
      expect(rings.single.first.latitude, closeTo(35.3, 1e-9));
      expect(rings.single.first.longitude, closeTo(-97.6, 1e-9));
    });

    test('a MultiPolygon zone yields one ring per part', () {
      final zone = {
        'geometry': {
          'type': 'MultiPolygon',
          'coordinates': [
            [
              [
                [-97.6, 35.3],
                [-97.4, 35.3],
              ]
            ],
            [
              [
                [-96.6, 34.3],
                [-96.4, 34.3],
              ]
            ],
          ],
        },
      };
      expect(ringsOfFeature(zone).length, 2);
    });

    test('a zone with no usable geometry yields nothing, not a throw', () {
      expect(ringsOfFeature(null), isEmpty);
      expect(ringsOfFeature({'geometry': null}), isEmpty);
      expect(ringsOfFeature({'geometry': {'type': 'Point'}}), isEmpty);
    });
  });

  test('zone urls are carried through so outlines can be built later', () {
    final doc = jsonEncode({
      'features': [
        {
          'geometry': null,
          'properties': {
            'event': 'Tornado Watch',
            'affectedZones': [
              'https://api.weather.gov/zones/county/OKC027',
              'https://api.weather.gov/zones/county/OKC083',
            ],
          },
        }
      ]
    });
    final a = parseAlerts(doc).single;
    expect(a.hasPolygon, isFalse);
    expect(a.zoneUrls.length, 2);
  });

  group('categories', () {
    test('the last word of the event name decides', () {
      expect(categoryOf('Tornado Warning'), AlertCategory.warning);
      expect(categoryOf('Severe Thunderstorm Watch'), AlertCategory.watch);
      expect(categoryOf('Winter Weather Advisory'), AlertCategory.advisory);
      expect(
        categoryOf('Special Weather Statement'),
        AlertCategory.advisory,
        reason: 'statements belong with the least urgent',
      );
    });

    test('a watch is not mistaken for a warning', () {
      // "Flash Flood Watch" contains neither word as a prefix, so a naive
      // contains() check would be ambiguous.
      expect(categoryOf('Flash Flood Watch'), AlertCategory.watch);
      expect(categoryOf('Flash Flood Warning'), AlertCategory.warning);
    });
  });

  group('parsing', () {
    test('an alert with no polygon is kept, not dropped', () {
      // This is the bug: watches are issued by county with no geometry at
      // all, so dropping them threw away nearly every watch.
      final alerts = parseAlerts(_doc([
        _feature(event: 'Tornado Watch'),
        _feature(event: 'Tornado Warning', ring: _box),
      ]));

      expect(alerts.length, 2);
      final watch = alerts.firstWhere((a) => a.event == 'Tornado Watch');
      expect(watch.hasPolygon, isFalse);
      expect(watch.category, AlertCategory.watch);
      expect(watch.areaDesc, 'Cleveland, OK',
          reason: 'the county list is the only geography a watch has');
    });

    test('polygons are read as lat/lon in the right order', () {
      final alerts = parseAlerts(_doc([
        _feature(event: 'Tornado Warning', ring: _box),
      ]));
      final ring = alerts.single.polygons.single;
      expect(ring.first.latitude, closeTo(35.3, 1e-9));
      expect(ring.first.longitude, closeTo(-97.6, 1e-9));
    });

    test('a MultiPolygon contributes one ring per part', () {
      final doc = jsonEncode({
        'features': [
          {
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                [_box],
                [_box],
              ],
            },
            'properties': {'event': 'Flood Warning'},
          }
        ]
      });
      expect(parseAlerts(doc).single.polygons.length, 2);
    });

    test('warnings and watches are coloured apart', () {
      final alerts = parseAlerts(_doc([
        _feature(event: 'Tornado Warning', ring: _box),
        _feature(event: 'Tornado Watch'),
      ]));
      final warning = alerts.firstWhere((a) => a.category == AlertCategory.warning);
      final watch = alerts.firstWhere((a) => a.category == AlertCategory.watch);
      expect(warning.color, isNot(watch.color));
    });

    test('junk does not throw', () {
      expect(parseAlerts('{}'), isEmpty);
      expect(parseAlerts('[]'), isEmpty);
      expect(parseAlerts(_doc([])), isEmpty);
      // A feature with a malformed geometry still yields the alert itself.
      final odd = jsonEncode({
        'features': [
          {
            'geometry': {'type': 'Point', 'coordinates': []},
            'properties': {'event': 'Dense Fog Advisory'},
          }
        ]
      });
      final alerts = parseAlerts(odd);
      expect(alerts.single.hasPolygon, isFalse);
      expect(alerts.single.category, AlertCategory.advisory);
    });
  });
}
