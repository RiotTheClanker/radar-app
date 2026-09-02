import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/src/rust/api/radar.dart';
import 'package:radar_app/ui/color_key.dart';

ColorScale _scale(
  List<(double, int)> stops, {
  bool interpolate = true,
  String unit = 'dBZ',
}) =>
    ColorScale(
      stops: [
        for (final (v, grey) in stops)
          ColorScaleStop(value: v, r: grey, g: grey, b: grey, a: 255),
      ],
      interpolate: interpolate,
      unit: unit,
      rfR: 119,
      rfG: 0,
      rfB: 125,
    );

Future<void> _pump(
  WidgetTester tester,
  ColorScale scale, {
  bool rangeFolded = false,
  Size size = const Size(360, 800),
  double? barHeight,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: barHeight == null
              ? ColorKey(scale: scale, rangeFolded: rangeFolded)
              : ColorKey(
                  scale: scale,
                  rangeFolded: rangeFolded,
                  barHeight: barHeight,
                ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('labels the ends of the range and shows the unit',
      (tester) async {
    await _pump(tester, _scale([(5, 20), (35, 128), (75, 255)]));

    expect(find.text('dBZ'), findsOneWidget);
    // 5 and 75 bound the scale, so both must appear somewhere.
    expect(find.text('5'), findsOneWidget);
    expect(find.text('75'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('larger values sit above smaller ones', (tester) async {
    await _pump(tester, _scale([(5, 20), (35, 128), (75, 255)]));

    final top = tester.getCenter(find.text('75'));
    final bottom = tester.getCenter(find.text('5'));
    expect(
      top.dy,
      lessThan(bottom.dy),
      reason: 'the scale must read high-at-top like every other legend',
    );
  });

  testWidgets('a negative-to-positive scale keeps both ends', (tester) async {
    // Velocity: inbound negative, outbound positive.
    await _pump(tester, _scale([(-30, 0), (0, 128), (30, 255)], unit: 'm/s'));

    expect(find.text('m/s'), findsOneWidget);
    expect(find.text('-30'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
  });

  testWidgets('range-folded swatch only appears when asked', (tester) async {
    final scale = _scale([(-30, 0), (30, 255)], unit: 'm/s');

    await _pump(tester, scale);
    expect(find.text('RF'), findsNothing);

    await _pump(tester, scale, rangeFolded: true);
    expect(find.text('RF'), findsOneWidget);
  });

  testWidgets('fits on a small phone without overflowing', (tester) async {
    // A long table with tightly spaced stops is the awkward case.
    await _pump(
      tester,
      _scale([for (var i = 0; i <= 40; i++) (i * 2.5, i * 6)]),
      size: const Size(320, 480),
    );

    expect(tester.takeException(), isNull);
    final box = tester.getRect(find.byType(ColorKey));
    expect(box.right, lessThanOrEqualTo(320));
    expect(box.height, lessThanOrEqualTo(480));
  });

  testWidgets('a stepped table still renders', (tester) async {
    await _pump(
      tester,
      _scale([(0, 0), (1, 90), (2, 180), (3, 255)],
          interpolate: false, unit: ''),
    );

    expect(tester.takeException(), isNull);
    // No unit means no unit label taking up room.
    expect(find.text(''), findsNothing);
  });

  testWidgets('a degenerate single-stop scale does not crash', (tester) async {
    await _pump(tester, _scale([(10, 128)]));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty scale renders nothing rather than an empty box',
      (tester) async {
    await _pump(tester, _scale([]));
    expect(tester.takeException(), isNull);
    expect(find.text('dBZ'), findsNothing);
  });

  testWidgets('a shortened key fits the room it was given', (tester) async {
    // A pane in a 2x2 on a landscape phone is shorter than the key's
    // natural height, and a key that overflows its own pane paints a
    // black-and-yellow stripe across the weather.
    await _pump(
      tester,
      _scale([for (var i = 0; i <= 40; i++) (i * 2.5, i * 6)]),
      size: const Size(200, 150),
      barHeight: 70,
    );

    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byType(ColorKey)).height, lessThanOrEqualTo(150));
  });

  testWidgets('shortening the key keeps both ends of the scale labelled',
      (tester) async {
    await _pump(
      tester,
      _scale([(5, 20), (35, 128), (75, 255)]),
      barHeight: 70,
    );

    // The point of the key is the mapping; a shorter bar may drop
    // intermediate ticks but the range has to stay unambiguous.
    expect(find.text('5'), findsOneWidget);
    expect(find.text('75'), findsOneWidget);
  });
}
