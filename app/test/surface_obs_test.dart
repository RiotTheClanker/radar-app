/// Surface observation parsing.
///
/// The fixture below is a real record from the Aviation Weather Center,
/// captured rather than invented, because the shape of this feed is the whole
/// risk in the fetcher: two of its fields are not the type they look like.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/surface_obs.dart';

/// One station exactly as the service sent it, trimmed of nothing.
///
/// Note `visib` and `wdir`: strings in a record where every neighbouring
/// field is a number.
const _real = '''
[{"icaoId":"KK82","receiptTime":"2026-09-03T16:37:35.278Z","obsTime":1788453300,
"reportTime":"2026-09-03T16:35:00.000Z","temp":33.3,"dewp":19,"wdir":190,
"wspd":13,"wgst":19,"visib":"10+","altim":1010.9,"qcField":6,
"metarType":"METAR","rawOb":"METAR KK82 031635Z AUTO 19013G19KT 10SM CLR 33/19",
"lat":39.7606,"lon":-98.7957,"elev":548,"name":"Smith Center Arpt, KS, US",
"cover":"CLR","clouds":[],"fltCat":"VFR"}]
''';

void main() {
  group('parsing a real record', () {
    test('reads every field the station plot and readout use', () {
      final obs = parseSurfaceObs(_real);
      expect(obs, hasLength(1));
      final o = obs.single;
      expect(o.stationId, 'KK82');
      expect(o.name, 'Smith Center Arpt, KS, US');
      expect(o.pos.latitude, closeTo(39.7606, 1e-6));
      expect(o.pos.longitude, closeTo(-98.7957, 1e-6));
      expect(o.tempC, closeTo(33.3, 1e-9));
      expect(o.dewpointC, closeTo(19, 1e-9));
      expect(o.windDirDeg, closeTo(190, 1e-9));
      expect(o.windKt, closeTo(13, 1e-9));
      expect(o.gustKt, closeTo(19, 1e-9));
      expect(o.altimeterHpa, closeTo(1010.9, 1e-9));
      expect(o.elevM, closeTo(548, 1e-9));
    });

    /// `obsTime` is seconds, and it is the observation rather than the
    /// receipt — a reading is not current because a server saw it late.
    test('takes the observation time, not the receipt time', () {
      final o = parseSurfaceObs(_real).single;
      expect(o.time.isUtc, isTrue);
      expect(o.time.millisecondsSinceEpoch, 1788453300 * 1000);
      // receiptTime is 16:37:35; obsTime is 16:35:00.
      expect(o.time.minute, 35);
      expect(o.time.second, 0);
    });
  });

  group('fields that are not the type they look like', () {
    /// A variable wind arrives as "VRB". Rounding that to a number would
    /// point an arrow in a direction the station explicitly did not report.
    test('a variable wind direction becomes unknown, not zero', () {
      final obs = parseSurfaceObs(
        '[{"icaoId":"KXXX","obsTime":1788453300,"lat":35.0,"lon":-97.0,'
        '"wdir":"VRB","wspd":8,"temp":20}]',
      );
      expect(obs.single.windDirDeg, isNull);
      expect(obs.single.windKt, closeTo(8, 1e-9),
          reason: 'the speed is still a number and still useful');
    });

    test('readNum copes with the mixed types this feed sends', () {
      expect(readNum(33.3), closeTo(33.3, 1e-9));
      expect(readNum(19), closeTo(19, 1e-9));
      expect(readNum('12.5'), closeTo(12.5, 1e-9));
      expect(readNum('10+'), isNull, reason: 'unlimited visibility');
      expect(readNum('VRB'), isNull, reason: 'variable wind');
      expect(readNum(null), isNull);
      expect(readNum(const []), isNull);
    });
  });

  group('rows that cannot be drawn', () {
    test('a station with no position is dropped', () {
      expect(
        parseSurfaceObs('[{"icaoId":"KXXX","obsTime":1788453300,"temp":20}]'),
        isEmpty,
      );
    });

    test('a station with no observation time is dropped', () {
      expect(
        parseSurfaceObs('[{"icaoId":"KXXX","lat":35.0,"lon":-97.0,"temp":20}]'),
        isEmpty,
      );
    });

    /// A missing dewpoint is ordinary weather, not a broken record — the
    /// station still belongs on the map.
    test('a station missing one reading is kept', () {
      final o = parseSurfaceObs(
        '[{"icaoId":"KXXX","obsTime":1788453300,"lat":35.0,"lon":-97.0,'
        '"temp":20}]',
      ).single;
      expect(o.tempC, closeTo(20, 1e-9));
      expect(o.dewpointC, isNull);
    });

    /// One that reports none of the three would be a marker with nothing in
    /// it, which reads as a station that is fine rather than one that is mute.
    test('a station reporting nothing at all is dropped', () {
      expect(
        parseSurfaceObs(
          '[{"icaoId":"KXXX","obsTime":1788453300,"lat":35.0,"lon":-97.0,'
          '"altim":1013.0}]',
        ),
        isEmpty,
      );
    });

    test('junk does not throw', () {
      expect(parseSurfaceObs('[]'), isEmpty);
      expect(parseSurfaceObs('{"error":"nope"}'), isEmpty);
      expect(parseSurfaceObs('[1,2,3]'), isEmpty);
      expect(parseSurfaceObs('[{}]'), isEmpty);
    });
  });

  group('staleness', () {
    SurfaceObs at(DateTime t) => parseSurfaceObs(
          '[{"icaoId":"KXXX","obsTime":${t.millisecondsSinceEpoch ~/ 1000},'
          '"lat":35.0,"lon":-97.0,"temp":20}]',
        ).single;

    /// Routine METARs are hourly, so an hour old is normal and must not be
    /// dimmed — otherwise most of the network looks broken most of the time.
    test('an hour-old reading is still current', () {
      final now = DateTime.now().toUtc();
      expect(at(now.subtract(const Duration(minutes: 59))).staleAt(now),
          isFalse);
    });

    test('past the cutoff it is stale', () {
      final now = DateTime.now().toUtc();
      expect(
        at(now.subtract(obsStaleAfter + const Duration(minutes: 1)))
            .staleAt(now),
        isTrue,
      );
    });

    test('the cutoff leaves room for a missed report', () {
      expect(obsStaleAfter, greaterThan(const Duration(minutes: 60)),
          reason: 'hourly reporting plus slack, or every station flickers');
    });
  });
}
