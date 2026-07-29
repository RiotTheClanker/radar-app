import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/terrain_tiles.dart';

void main() {
  group('terrarium decoding', () {
    test('the zero point is sea level', () {
      // 32768 m is subtracted, so R=128 G=0 B=0 is exactly 0 m.
      expect(terrariumHeight(128, 0, 0), 0);
    });

    test('the green channel is one metre per step', () {
      expect(terrariumHeight(128, 1, 0), 1);
      expect(terrariumHeight(128, 255, 0), 255);
    });

    test('the red channel is 256 m per step', () {
      expect(terrariumHeight(129, 0, 0), 256);
      expect(terrariumHeight(130, 0, 0), 512);
    });

    test('the blue channel is the sub-metre part', () {
      expect(terrariumHeight(128, 0, 128), closeTo(0.5, 1e-9));
      expect(terrariumHeight(128, 0, 64), closeTo(0.25, 1e-9));
    });

    test('below sea level comes out negative', () {
      // The Dead Sea shore, about -430 m.
      expect(terrariumHeight(126, 82, 0), -430);
      expect(terrariumHeight(127, 255, 0), -1);
    });

    test('real summits land where they should', () {
      // Everest at 8849 m: 8849 + 32768 = 41617 = 162*256 + 145.
      expect(terrariumHeight(162, 145, 0), 8849);
      // Denali at 6190 m: 6190 + 32768 = 38958 = 152*256 + 46.
      expect(terrariumHeight(152, 46, 0), 6190);
    });

    test('the full channel range stays inside what f16 can hold', () {
      // The shader stores heights as half floats, whose largest finite value
      // is 65504. Anything the encoding can produce for real terrain must
      // fit, or peaks would come back as infinity.
      final highest = terrariumHeight(255, 255, 255);
      final lowest = terrariumHeight(0, 0, 0);
      expect(highest, lessThan(65504));
      expect(lowest, greaterThan(-65504));
    });
  });
}
