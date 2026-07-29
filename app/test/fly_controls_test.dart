import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/fly_controls.dart';

/// Wraps a control so the test can take it off screen while it is still
/// being held — hiding the controls or switching field does exactly this.
Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  required bool visible,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: visible ? child : const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('FlyStick', () {
    testWidgets('reports movement while dragged and zero on release',
        (tester) async {
      var value = Offset.zero;
      final stick = FlyStick(onChanged: (v) => value = v);

      await _pump(tester, child: stick, visible: true);

      final center = tester.getCenter(find.byType(FlyStick));
      final drag = await tester.startGesture(center);
      await drag.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(value.dy, lessThan(0), reason: 'dragging up should move forward');

      await drag.up();
      await tester.pump();
      expect(value, Offset.zero, reason: 'releasing must stop the camera');
    });

    testWidgets('reports zero when taken off screen mid-drag', (tester) async {
      var value = Offset.zero;
      final stick = FlyStick(onChanged: (v) => value = v);

      await _pump(tester, child: stick, visible: true);
      final drag = await tester.startGesture(tester.getCenter(find.byType(FlyStick)));
      await drag.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(value, isNot(Offset.zero));

      // No pointer-up ever arrives — the widget just goes away.
      await _pump(tester, child: stick, visible: false);
      expect(
        value,
        Offset.zero,
        reason: 'a stick removed while held must not leave the camera flying',
      );
      // No pointer-up is sent: the point is that one never comes.
    });
  });

  group('HoldButton', () {
    testWidgets('reports down while pressed and up on release', (tester) async {
      var down = false;
      final button = HoldButton(
        icon: Icons.keyboard_arrow_up,
        onChanged: (v) => down = v,
      );

      await _pump(tester, child: button, visible: true);

      final press =
          await tester.startGesture(tester.getCenter(find.byType(HoldButton)));
      await tester.pump();
      expect(down, isTrue);

      await press.up();
      await tester.pump();
      expect(down, isFalse);
    });

    testWidgets('reports up when taken off screen while held', (tester) async {
      var down = false;
      final button = HoldButton(
        icon: Icons.keyboard_arrow_up,
        onChanged: (v) => down = v,
      );

      await _pump(tester, child: button, visible: true);
      await tester.startGesture(tester.getCenter(find.byType(HoldButton)));
      await tester.pump();
      expect(down, isTrue);

      await _pump(tester, child: button, visible: false);
      expect(
        down,
        isFalse,
        reason: 'a button removed while held must not leave the camera climbing',
      );
      // No pointer-up is sent: the point is that one never comes.
    });
  });
}
