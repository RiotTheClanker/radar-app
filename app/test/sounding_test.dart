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
