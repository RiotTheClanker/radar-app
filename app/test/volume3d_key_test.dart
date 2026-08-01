import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/src/rust/api/radar.dart';
import 'package:radar_app/ui/color_key.dart';
import 'package:radar_app/ui/hydro_legend.dart';
import 'package:radar_app/ui/volume3d_screen.dart';

/// Every 3D field is supposed to get a key. One shipped where only the
/// classified field did, because the two conditions that pick the key were
/// nested inline and an edit left both testing for 'HCA' — so the colour-scale
/// branch was unreachable and reflectivity, wind, ZDR and CC rendered with
/// nothing to read them against. The choice is a function now, so this can
/// walk the field menu and check each one.
ColorScale _scale(String unit) => ColorScale(
      stops: const [
        ColorScaleStop(value: 0, r: 0, g: 0, b: 0, a: 255),
        ColorScaleStop(value: 50, r: 255, g: 255, b: 255, a: 255),
      ],
      interpolate: true,
      unit: unit,
      rfR: 119,
      rfG: 0,
      rfB: 125,
    );

void main() {
  test('every field in the menu gets a key', () {
    expect(volumeFieldMoments, isNotEmpty);
    for (final moment in volumeFieldMoments) {
      expect(
        volumeKey(moment, _scale('dBZ')),
        isNotNull,
        reason: '$moment renders with no key at all',
      );
    }
  });

  test('classified fields get the class list, quantities get a scale', () {
    for (final moment in volumeFieldMoments) {
      final key = volumeKey(moment, _scale('dBZ'));
      if (moment == 'HCA') {
        // A colour bar labelled with class ids is not readable as values.
        expect(key, isA<HydroLegend>(), reason: moment);
      } else {
        expect(key, isA<ColorKey>(), reason: moment);
      }
    }
  });

  test('the class list does not depend on a scale arriving', () {
    // Its colours are compiled in, so it must not wait on a bridge call that
    // is skipped for this field.
    expect(volumeKey('HCA', null), isA<HydroLegend>());
  });

  test('a field with no scale yet draws no key rather than an empty one', () {
    expect(volumeKey('REF', null), isNull);
  });

  test('only the velocity fields show the range-folded swatch', () {
    for (final moment in volumeFieldMoments) {
      final key = volumeKey(moment, _scale('m/s'));
      if (key is! ColorKey) continue;
      expect(
        key.rangeFolded,
        moment == 'VEL' || moment == 'SRM',
        reason: '$moment range-folded swatch',
      );
    }
  });
}
