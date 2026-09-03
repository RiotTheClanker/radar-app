/// HRRR index parsing and byte-range arithmetic.
///
/// This is where fetching the wrong field is silent: every record in the
/// file decodes as valid GRIB2, so asking for the wrong byte range gets you a
/// perfectly good map of the wrong quantity. The fixture is real index text.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/hrrr_fetcher.dart';

/// Lines from a real `hrrr.t12z.wrfsfcf00.grib2.idx`, kept in order and
/// unedited. Note there are three CAPE records with different levels.
const _idx = '''
104:62795236:d=2026090312:HGT:cloud ceiling:anl:
105:63553836:d=2026090312:CAPE:surface:anl:
106:64378843:d=2026090312:CIN:surface:anl:
131:88501526:d=2026090312:HLCY:3000-0 m above ground:anl:
132:90419847:d=2026090312:HLCY:1000-0 m above ground:anl:
148:112209107:d=2026090312:CAPE:180-0 mb above ground:anl:
149:113109028:d=2026090312:CIN:180-0 mb above ground:anl:
152:119844173:d=2026090312:CAPE:90-0 mb above ground:anl:
''';

void main() {
  group('finding a field in the index', () {
    test('surface CAPE gets the range the real file uses', () {
      final r = rangeForTest(_idx, capeField)!;
      expect(r.start, 63553836);
      // The next record's offset, minus one — GRIB2 messages are contiguous
      // and the index carries no lengths.
      expect(r.end, 64378842);
      expect(r.end! - r.start + 1, 825007, reason: 'about 800 KB');
    });

    /// Three records contain "CAPE". Matching loosely would fetch a
    /// mixed-layer parcel and label it surface-based — different numbers,
    /// same units, no error anywhere.
    test('the level is part of the match, not just the parameter', () {
      expect(rangeForTest(_idx, ':CAPE:surface:')!.start, 63553836);
      expect(
        rangeForTest(_idx, ':CAPE:180-0 mb above ground:')!.start,
        112209107,
      );
      expect(
        rangeForTest(_idx, ':CAPE:90-0 mb above ground:')!.start,
        119844173,
      );
    });

    test('a field that is not there returns null rather than guessing', () {
      expect(rangeForTest(_idx, ':NOSUCHFIELD:surface:'), isNull);
    });

    /// The last record has no successor to bound it, so it runs to the end of
    /// the file and the range has to stay open.
    test('the final record gets an open-ended range', () {
      final r = rangeForTest(_idx, ':CAPE:90-0 mb above ground:')!;
      expect(r.start, 119844173);
      expect(r.end, isNull);
    });

    test('junk does not throw', () {
      expect(rangeForTest('', capeField), isNull);
      expect(rangeForTest('nonsense\nlines\n', capeField), isNull);
      expect(rangeForTest('1:notanumber:d=x:CAPE:surface:', capeField), isNull);
    });
  });

  group('a forecast must not read as a measurement', () {
    /// Every other layer in this app was seen by an instrument. This one was
    /// computed, and it is drawn beside live warnings — so the run time is
    /// not decoration, it is the difference between "it is unstable" and "a
    /// model thought so three hours ago".
    test('a field carries the run it came from, not when it was fetched', () {
      final run = DateTime.utc(2026, 9, 3, 12);
      final f = HrrrField(Uint8List(0), run);
      expect(f.runTime, run);
      expect(f.runTime.isUtc, isTrue,
          reason: 'model runs are named in UTC, and a local hour would lie');
    });
  });

  group('object keys', () {
    test('names the run the way the bucket lays it out', () {
      expect(
        keyForTest(DateTime.utc(2026, 9, 3, 12)),
        'hrrr.20260903/conus/hrrr.t12z.wrfsfcf00.grib2',
      );
    });

    /// Zero padding matters in both places: hrrr.2026913 and t6z are both
    /// 404s, and a 404 here reads as "the model is down".
    test('pads the date and the hour', () {
      expect(
        keyForTest(DateTime.utc(2026, 1, 5, 6)),
        'hrrr.20260105/conus/hrrr.t06z.wrfsfcf00.grib2',
      );
      expect(
        keyForTest(DateTime.utc(2026, 12, 31, 0)),
        'hrrr.20261231/conus/hrrr.t00z.wrfsfcf00.grib2',
      );
    });
  });
}
