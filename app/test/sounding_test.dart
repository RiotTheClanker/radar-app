import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/sounding_fetcher.dart';

/// A GSD response shaped like the real thing: a title line, the three header
/// line types, then data levels. Values are the documented scalings —
/// pressure in tenths of a millibar, temperature in tenths of a degree.
const _gsd = '''
RAOB     OUN  observations at 00Z 29 Jul 26

    254    1  72357     0      0
      1  23  72357   3522  -9744    357  99999
      2  99999  99999  99999  99999  99999  99999
      3          OUN  99999  99999     kt
      9   9720    357    294    233    170     12
      4   9250    775    271    221    180     15
      5   8500   1487    221    191    200     20
      4   7000   3125    118     28    215     30
      4   5000   5840   -108   -238    240     45
      7   2000  11890   -602  99999    260     75
      4   1000  16400   -638  99999  99999  99999
''';

void main() {
  group('GSD parsing', () {
    test('reads the levels and scales the units', () {
      final s = parseGsdSounding(_gsd)!;

      expect(s.station, 'OUN');
      expect(s.levels.length, 7);

      // Surface: 972.0 hPa, 35.7 C, dewpoint 29.4 C, 170 deg at 12 kt.
      final sfc = s.surface!;
      expect(sfc.pressureHpa, closeTo(972.0, 1e-9));
      expect(sfc.heightM, closeTo(357, 1e-9));
      expect(sfc.tempC, closeTo(29.4, 1e-9));
      expect(sfc.dewpointC, closeTo(23.3, 1e-9));
      expect(sfc.windDirDeg, closeTo(170, 1e-9));
      expect(sfc.windKt, closeTo(12, 1e-9));
    });

    test('negative temperatures aloft survive the scaling', () {
      final s = parseGsdSounding(_gsd)!;
      final l500 = s.levels.firstWhere((l) => l.pressureHpa == 500.0);
      expect(l500.tempC, closeTo(-10.8, 1e-9));
      expect(l500.dewpointC, closeTo(-23.8, 1e-9));
    });

    test('99999 becomes null rather than a real reading', () {
      final s = parseGsdSounding(_gsd)!;
      final trop = s.levels.firstWhere((l) => l.pressureHpa == 200.0);
      expect(trop.dewpointC, isNull, reason: 'missing must not read as 9999.9');
      expect(trop.tempC, closeTo(-60.2, 1e-9));

      final top = s.levels.firstWhere((l) => l.pressureHpa == 100.0);
      expect(top.hasWind, isFalse);
    });

    test('levels come back surface first', () {
      final s = parseGsdSounding(_gsd)!;
      final pressures = [for (final l in s.levels) l.pressureHpa];
      final descending = [...pressures]..sort((a, b) => b.compareTo(a));
      expect(pressures, descending);
    });

    test('the observation time is read from the header', () {
      final s = parseGsdSounding(_gsd)!;
      expect(s.time, DateTime.utc(2026, 7, 29, 0));
    });

    test('winds in m/s are converted to knots', () {
      final ms = _gsd.replaceFirst('     kt', '     ms');
      final s = parseGsdSounding(ms)!;
      // 12 m/s is about 23.3 kt.
      expect(s.surface!.windKt, closeTo(23.3, 0.1));
    });

    test('prose and empty responses yield nothing, not an exception', () {
      expect(parseGsdSounding(''), isNull);
      expect(parseGsdSounding('No data available for this time'), isNull);
      expect(parseGsdSounding('   \n\n  '), isNull);
    });

    test('a truncated level line is skipped, the rest still parse', () {
      final broken = _gsd.replaceFirst(
        '      4   7000   3125    118     28    215     30',
        '      4   7000   3125',
      );
      final s = parseGsdSounding(broken)!;
      expect(s.levels.length, 6);
      expect(s.levels.any((l) => l.pressureHpa == 700.0), isFalse);
    });
  });

  _spcTests();

  group('nearest launch site', () {
    test('picks the obvious one', () {
      // Twin Lakes radar, Oklahoma — Norman is the launch site.
      expect(nearestRaobSite(35.33, -97.28).id, 'OUN');
      // Miami radar.
      expect(nearestRaobSite(25.6, -80.4).id, 'MFL');
      // Seattle area.
      expect(nearestRaobSite(48.2, -122.5).id, 'UIL');
    });

    test('longitude is scaled by latitude', () {
      // Without the cos(lat) term a degree of longitude in the north would
      // count as much as one at the equator and pull the wrong site.
      expect(nearestRaobSite(47.6, -111.0).id, 'TFX');
    });

    test('always returns something', () {
      expect(nearestRaobSite(0, 0).id, isNotEmpty);
    });
  });
}

// SPC's observed sounding format, which is what the app asks for first.
const _spc = '''
%TITLE%
 OUN   260729/0000

   LEVEL       HGHT       TEMP       DWPT       WDIR       WSPD
-------------------------------------------------------------------
%RAW%
 1000.00,    111.00,     24.20,     21.30,    160.00,     15.00
  925.00,    775.00,     20.10,     18.20,    180.00,     20.00
  850.00,   1487.00,     15.60,     12.10,    200.00,     25.00
  700.00,   3125.00,      5.20,     -8.30,    215.00,     30.00
  500.00,   5840.00,    -10.80,  -9999.00,    240.00,     45.00
  250.00,  10360.00,    -48.90,  -9999.00,    255.00,     70.00
%END%
''';

void _spcTests() {
  group('SPC sounding format', () {
    test('reads levels straight off, no scaling', () {
      final s = parseSpcSounding(_spc)!;
      expect(s.station, 'OUN');
      expect(s.levels.length, 6);
      expect(s.surface!.pressureHpa, closeTo(1000, 1e-9));
      expect(s.surface!.tempC, closeTo(24.2, 1e-9));
      expect(s.surface!.dewpointC, closeTo(21.3, 1e-9));
      expect(s.surface!.windKt, closeTo(15, 1e-9));
    });

    test('-9999 is missing, not a temperature', () {
      final s = parseSpcSounding(_spc)!;
      final l500 = s.levels.firstWhere((l) => l.pressureHpa == 500);
      expect(l500.tempC, closeTo(-10.8, 1e-9));
      expect(l500.dewpointC, isNull);
    });

    test('anything without the raw block is not a sounding', () {
      expect(parseSpcSounding(''), isNull);
      expect(parseSpcSounding('<html>404 Not Found</html>'), isNull);
    });
  });

  group('launch slots', () {
    test('walks back through 00Z and 12Z, most recent first', () {
      final t = synopticTimes(DateTime.utc(2026, 7, 29, 5, 30));
      expect(t.first, DateTime.utc(2026, 7, 29, 0));
      expect(t[1], DateTime.utc(2026, 7, 28, 12));
      expect(t[2], DateTime.utc(2026, 7, 28, 0));
    });

    test('afternoon starts from that morning 12Z', () {
      final t = synopticTimes(DateTime.utc(2026, 7, 29, 18));
      expect(t.first, DateTime.utc(2026, 7, 29, 12));
    });

    test('the url carries the launch stamp and station', () {
      expect(
        spcSoundingUrl('oun', DateTime.utc(2026, 7, 29, 0)),
        'https://www.spc.noaa.gov/exper/soundings/26072900_OBS/OUN.txt',
      );
    });
  });
}
