import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/model/models.dart';

void main() {
  group('Product', () {
    test('tilted Level 3 products build the N<tilt><suffix> mnemonic', () {
      const ref = Product('Reflectivity', 'REF', tiltSuffix: 'B');
      expect(ref.code(0), 'N0B');
      expect(ref.code(3), 'N3B');
      expect(ref.hasTilts, isTrue);
      expect(ref.isLevel2, isFalse);
    });

    test('a fixed code ignores the tilt', () {
      const stp = Product('Storm Total Precip', 'STP', fixedCode: 'DTA');
      expect(stp.code(0), 'DTA');
      expect(stp.code(2), 'DTA');
    });

    test('Level 2 moments have tilts, volume products do not', () {
      const vel = Product('Velocity', 'L2 VEL', l2Moment: 'VEL');
      const vil = Product('VIL', 'VIL', l2Moment: 'VIL', l2Volume: true);
      expect(vel.isLevel2, isTrue);
      expect(vel.hasTilts, isTrue);
      expect(vil.isLevel2, isTrue);
      expect(vil.hasTilts, isFalse);
    });

    test('the mosaic is neither Level 2 nor tilted', () {
      expect(mrmsProduct.isMrms, isTrue);
      expect(mrmsProduct.isLevel2, isFalse);
      expect(mrmsProduct.hasTilts, isFalse);
    });

    // The mosaic hand-over compares the live product against `defaultProduct`
    // by identity, so these two must stay the same const instance.
    test('defaultProduct is the first Level 3 product, not a copy', () {
      expect(identical(defaultProduct, l3Products.first), isTrue);
    });
  });

  group('Basemap', () {
    test('defaultBasemap is the first entry, not a copy', () {
      expect(identical(defaultBasemap, basemaps.first), isTrue);
    });

    // Required by CARTO, OSM, Esri and OpenTopoMap's terms of use — whatever
    // the UI looks like, every basemap has to carry its credit.
    test('every basemap carries a non-empty attribution', () {
      for (final b in basemaps) {
        expect(b.attribution, isNotEmpty, reason: b.label);
        expect(b.url, contains('{z}'), reason: b.label);
      }
    });
  });

  group('LightningSource', () {
    test('off is the only source that is not on', () {
      expect(LightningSource.off.on, isFalse);
      for (final s in LightningSource.values.where((s) => s != LightningSource.off)) {
        expect(s.on, isTrue, reason: s.name);
      }
    });

    test('both drives each network', () {
      expect(LightningSource.both.usesBlitzortung, isTrue);
      expect(LightningSource.both.usesGlm, isTrue);
      expect(LightningSource.glm.usesBlitzortung, isFalse);
      expect(LightningSource.blitzortung.usesGlm, isFalse);
    });
  });

  group('geo', () {
    test('distance and bearing due north', () {
      final (d, b) = distanceBearing(
        const LatLng(35.0, -97.0),
        const LatLng(36.0, -97.0),
      );
      expect(d, closeTo(111.2, 1.0));
      expect(b, closeTo(0, 0.5));
    });

    test('distance and bearing due east', () {
      final (d, b) = distanceBearing(
        const LatLng(0.0, 0.0),
        const LatLng(0.0, 1.0),
      );
      expect(d, closeTo(111.2, 1.0));
      expect(b, closeTo(90, 0.5));
    });

    test('bearing is normalised to 0-360', () {
      final (_, b) = distanceBearing(
        const LatLng(35.0, -97.0),
        const LatLng(34.0, -98.0),
      );
      expect(b, greaterThanOrEqualTo(0));
      expect(b, lessThan(360));
    });

    test('beam height rises with range and with elevation', () {
      final low = beamHeightM(100000, 0.5);
      final far = beamHeightM(200000, 0.5);
      final steep = beamHeightM(100000, 3.5);
      expect(far, greaterThan(low));
      expect(steep, greaterThan(low));
      // A 0.5 deg beam at 100 km sits a few thousand feet up, not tens.
      expect(low * 3.28084 / 1000.0, inInclusiveRange(2.0, 7.0));
    });

    test('age labels switch from minutes to hours at an hour', () {
      expect(ageLabel(const Duration(minutes: 12)), '12m');
      expect(ageLabel(const Duration(minutes: 59)), '59m');
      expect(ageLabel(const Duration(minutes: 60)), '1h');
      expect(ageLabel(const Duration(hours: 3, minutes: 10)), '3h');
    });

    test('nearest-site distance is smaller for the closer site', () {
      final near = squaredDistance(35.0, -97.0, 35.3, -97.3);
      final far = squaredDistance(35.0, -97.0, 40.0, -105.0);
      expect(near, lessThan(far));
    });
  });
}
