import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/ui/geo.dart';

/// KTLX, and a couple of sites far enough north and south to catch a ring
/// that is only right near the latitude it was drawn at.
const _ktlx = LatLng(35.3331, -97.2778);
const _farNorth = LatLng(64.5, -147.5); // near KPAFG, Fairbanks
const _equatorish = LatLng(13.45, 144.8); // near PGUA, Guam

void main() {
  group('geodesicRing', () {
    test('every point on the ring is the requested distance out', () {
      // The property the drawn ring is supposed to have, and the one a
      // screen-space circle does not: constant great-circle distance at
      // every bearing, not just due south of the centre.
      for (final centre in [_ktlx, _farNorth, _equatorish]) {
        for (final km in [10.0, 50.0, 150.0, 230.0]) {
          final ring = geodesicRing(centre, km);
          for (final p in ring) {
            final (d, _) = distanceBearing(centre, p);
            expect(
              d,
              closeTo(km, 0.01),
              reason: '$km km ring around $centre was $d km at $p',
            );
          }
        }
      }
    });

    test('the error a screen circle would make grows with radius', () {
      // Guards the reason for the fix rather than just the fix. Comparing
      // the north-south extent against the east-west extent shows how far
      // from circular a true constant-distance ring is: if these matched,
      // a screen circle would have been fine.
      double eccentricity(double km) {
        final ring = geodesicRing(_ktlx, km);
        var nsMax = 0.0, ewMax = 0.0;
        for (final p in ring) {
          nsMax = (p.latitude - _ktlx.latitude).abs() > nsMax
              ? (p.latitude - _ktlx.latitude).abs()
              : nsMax;
          ewMax = (p.longitude - _ktlx.longitude).abs() > ewMax
              ? (p.longitude - _ktlx.longitude).abs()
              : ewMax;
        }
        return ewMax / nsMax;
      }

      // Degrees of longitude are shorter than degrees of latitude at this
      // latitude, so the ring is always wider in degrees than it is tall.
      expect(eccentricity(50), greaterThan(1.1));
      expect(eccentricity(230), greaterThan(eccentricity(50)));
    });

    test('the ring closes on itself', () {
      final ring = geodesicRing(_ktlx, 120);
      expect(ring.first.latitude, closeTo(ring.last.latitude, 1e-9));
      expect(ring.first.longitude, closeTo(ring.last.longitude, 1e-9));
    });

    test('a ring spanning the antimeridian stays continuous', () {
      // Guam is close enough to 180 that a 230 km ring crosses it. An
      // unwrapped ring jumps +179 -> -179 and draws a line back across the
      // whole map.
      final ring = geodesicRing(_equatorish, 230);
      for (var i = 1; i < ring.length; i++) {
        final step = (ring[i].longitude - ring[i - 1].longitude).abs();
        expect(step, lessThan(10),
            reason: 'longitude jumped $step deg between consecutive points');
      }
    });

    test('a degenerate zero-radius ring collapses to the centre', () {
      for (final p in geodesicRing(_ktlx, 0)) {
        expect(p.latitude, closeTo(_ktlx.latitude, 1e-9));
        expect(p.longitude, closeTo(_ktlx.longitude, 1e-9));
      }
    });
  });

  group('distanceBearing', () {
    test('cardinal bearings come out where expected', () {
      final (_, north) = distanceBearing(_ktlx, LatLng(36.3331, -97.2778));
      final (_, east) = distanceBearing(_ktlx, LatLng(35.3331, -96.2778));
      expect(north, closeTo(0, 0.5));
      expect(east, closeTo(90, 0.5));
    });

    test('a known separation matches the published distance', () {
      // KTLX to KFWS is very nearly due south — 2.76 degrees of latitude at
      // ~111.2 km per degree, so about 307 km, and the bearing confirms it
      // is the latitude difference doing the work.
      final (d, brg) = distanceBearing(_ktlx, const LatLng(32.5731, -97.3031));
      expect(d, closeTo(307, 3));
      expect(brg, closeTo(180, 1));
    });

    test('distance to itself is zero', () {
      final (d, _) = distanceBearing(_ktlx, _ktlx);
      expect(d, closeTo(0, 1e-9));
    });
  });

  group('beamHeightM', () {
    test('the beam climbs with range at a fixed tilt', () {
      final near = beamHeightM(50000, 0.5);
      final far = beamHeightM(200000, 0.5);
      expect(far, greaterThan(near));
      // 4/3-earth at 0.5 deg puts the 200 km beam around 4 km up.
      expect(far, closeTo(4000, 600));
    });

    test('a higher tilt is higher at the same range', () {
      expect(beamHeightM(100000, 3.5), greaterThan(beamHeightM(100000, 0.5)));
    });

    test('zero range is at the radar', () {
      expect(beamHeightM(0, 0.5), closeTo(0, 1e-6));
    });
  });
}
