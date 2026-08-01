import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/hydrometeor.dart';
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

  test('the class list runs heaviest first, so the filter eats it upward', () {
    final legend = volumeKey('HCA', null) as HydroLegend;
    expect(legend.classes.first.label, 'Hail / rain');
    expect(legend.classes.last.label, 'Ground clutter');
    expect(
      legend.classes.map((c) => c.id).toList(),
      hydrometeorBySeverity.reversed.map((c) => c.id).toList(),
    );
  });

  test('the key crosses out exactly what the filter is hiding', () {
    // Both sides walk hydrometeorBySeverity, which is checked against the
    // renderer's own ordering in hydrometeor_test.
    for (var cutoff = 0; cutoff < hydrometeorBySeverity.length; cutoff++) {
      final legend = volumeKey('HCA', null, hcaCutoff: cutoff) as HydroLegend;
      expect(
        legend.hidden,
        hydrometeorBySeverity.take(cutoff).map((c) => c.id).toSet(),
        reason: 'cutoff $cutoff',
      );
      // Hidden or not, every class stays listed: vanishing from the key
      // leaves you unable to tell "filtered out" from "never there".
      expect(legend.classes.length, hydrometeorBySeverity.length);
    }
  });

  test('the filter label names the lightest class still showing', () {
    expect(hcaFilterLabel(0), 'all classes');
    expect(hcaFilterLabel(5), 'Rain and above');
    expect(hcaFilterLabel(7), 'Heavy rain and above');
    expect(hcaFilterLabel(8), 'Graupel and above');
    expect(hcaFilterLabel(9), 'Hail / rain only');
    // A slider that overruns must still read sensibly.
    expect(hcaFilterLabel(-1), 'all classes');
    expect(hcaFilterLabel(99), 'Hail / rain only');
  });

  test('every filter step changes what is shown', () {
    // A stop that hides nothing new is a stop that does nothing when dragged
    // onto, which reads as a broken slider.
    final seen = <String>{};
    for (var cutoff = 0; cutoff < hydrometeorBySeverity.length; cutoff++) {
      final legend = volumeKey('HCA', null, hcaCutoff: cutoff) as HydroLegend;
      expect(seen.add(legend.hidden.toList().join(',')), isTrue,
          reason: 'cutoff $cutoff hides the same classes as an earlier stop');
    }
  });

  testWidgets('a filtered class is drawn struck through, not just flagged',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: volumeKey('HCA', null, hcaCutoff: 5)),
    ));
    Text textFor(String label) => tester.widget<Text>(find.text(label));
    // Rain is the lowest class still showing at cutoff 5; wet snow is the
    // highest one hidden.
    expect(textFor('Rain').style?.decoration, isNot(TextDecoration.lineThrough));
    expect(textFor('Wet snow').style?.decoration, TextDecoration.lineThrough);
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
