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

  test('a hidden class stays listed, crossed out', () {
    // Vanishing from the key would leave you unable to tell a class you
    // filtered out from one the radar never saw — and no way to switch it
    // back on, since the row is the switch.
    final legend = volumeKey('HCA', null, hiddenClasses: {4, 10}) as HydroLegend;
    expect(legend.classes.length, hydrometeorBySeverity.length);
    expect(legend.hidden, {4, 10});
  });

  test('any combination is reachable, not just a prefix of some order', () {
    // The whole reason this is a per-class filter rather than a slider: the
    // classes have no natural order, so "graupel and hail only" has to be
    // expressible without an ordering that happens to put them adjacent.
    final keep = {6, 10};
    final hidden = {
      for (final c in hydrometeorBySeverity)
        if (!keep.contains(c.id)) c.id,
    };
    final legend = volumeKey('HCA', null, hiddenClasses: hidden) as HydroLegend;
    expect(
      legend.classes.where((c) => !legend.hidden.contains(c.id)).map((c) => c.label),
      unorderedEquals(['Graupel', 'Hail / rain']),
    );
  });

  testWidgets('a filtered class is drawn struck through, not just flagged',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: volumeKey('HCA', null, hiddenClasses: {5}, onToggle: (_) {}),
      ),
    ));
    Text textFor(String label) => tester.widget<Text>(find.text(label));
    expect(textFor('Rain').style?.decoration, isNot(TextDecoration.lineThrough));
    expect(textFor('Wet snow').style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('tapping a class reports that class', (tester) async {
    final tapped = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: volumeKey('HCA', null, onToggle: tapped.add),
      ),
    ));
    await tester.tap(find.text('Graupel'));
    await tester.tap(find.text('Ground clutter'));
    expect(tapped, [6, 1]);
  });

  testWidgets('the key says it can be tapped, and offers a way back',
      (tester) async {
    // A colour key is not somewhere people expect to find controls, so it has
    // to say so; and having switched ten classes off one at a time, nobody
    // wants to switch them back on one at a time.
    Future<void> pump(Set<int> hidden) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: volumeKey('HCA', null,
                hiddenClasses: hidden, onToggle: (_) {}, onShowAll: () {}),
          ),
        ));

    await pump({});
    expect(find.text('Tap to filter'), findsOneWidget);
    expect(find.text('Show all'), findsNothing);

    await pump({7});
    expect(find.text('Show all'), findsOneWidget);
  });

  testWidgets('a plain legend has no tap targets', (tester) async {
    // The 2D map draws the NWS's own product, which there is no palette of
    // ours to filter. Its key floats over a draggable map, so it must not
    // swallow gestures for a filter it does not have.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: volumeKey('HCA', null)),
    ));
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('Tap to filter'), findsNothing);
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
