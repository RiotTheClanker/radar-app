import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/toolbar.dart';

/// The map's top bar carries this many buttons. At ~40dp each they need more
/// width than a phone has in portrait, which is what used to push the last few
/// off the edge of the screen.
const _actionKeys = [
  'lightning',
  'volume3d',
  'future',
  'severe',
  'basemap',
  'location',
  'cursor',
  'more',
  'reload',
  'inspect',
];

/// Pumps a toolbar with the same padding and margins the real bars use.
Future<void> _pumpBar(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: ToolBar(
              status: const [
                Text(
                  'KTLX',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                Text('L2 REF 0.5°', style: TextStyle(fontSize: 12)),
              ],
              actions: [
                for (final k in _actionKeys)
                  IconButton(
                    key: ValueKey(k),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {},
                    icon: const Icon(Icons.layers, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('portrait phone keeps every button on screen', (tester) async {
    const size = Size(360, 800);
    await _pumpBar(tester, size);

    for (final k in _actionKeys) {
      final r = tester.getRect(find.byKey(ValueKey(k)));
      expect(
        r.left >= 0 && r.right <= size.width,
        isTrue,
        reason: '"$k" sits at $r, outside the ${size.width}px-wide screen',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow portrait wraps the buttons onto more than one line',
      (tester) async {
    await _pumpBar(tester, const Size(360, 800));

    final tops = <double>{
      for (final k in _actionKeys) tester.getRect(find.byKey(ValueKey(k))).top,
    };
    expect(tops.length, greaterThan(1),
        reason: 'the buttons cannot all fit on one line at 360px');
  });

  testWidgets('a wide window still lays the bar out on one line',
      (tester) async {
    const size = Size(1280, 800);
    await _pumpBar(tester, size);

    final tops = <double>{
      for (final k in _actionKeys) tester.getRect(find.byKey(ValueKey(k))).top,
    };
    expect(tops.length, 1, reason: 'everything fits, so it should be one run');

    // Status on the left, buttons pushed over to the right.
    final firstButton = tester.getRect(find.byKey(const ValueKey('lightning')));
    final label = tester.getRect(find.text('KTLX'));
    expect(label.right, lessThan(firstButton.left));
    expect(
      tester.getRect(find.byKey(const ValueKey('inspect'))).right,
      greaterThan(size.width / 2),
    );
    expect(tester.takeException(), isNull);
  });
}
