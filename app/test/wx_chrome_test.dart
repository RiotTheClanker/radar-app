import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/pane_models.dart';
import 'package:radar_app/ui/wx_theme.dart';

/// Roughly what the real product bar carries: five product buttons, a menu,
/// four tilts, and the tool toggles pinned on the right. At ~40dp each these
/// need more width than a phone has in portrait — the case that used to push
/// the last few buttons off the edge of the screen.
Future<void> _pumpBar(
  WidgetTester tester,
  Size size, {
  List<Widget>? leading,
  List<Widget>? trailing,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: wxTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: WxBar(
            leading: leading ??
                [
                  for (final p in quickProducts) WxButton(label: p.bareShort),
                  for (var t = 0; t < 4; t++)
                    WxButton(label: '${t + 1}', dense: true),
                ],
            trailing: trailing ??
                const [
                  WxButton(icon: Icons.ads_click, dense: true),
                  WxButton(icon: Icons.timeline, dense: true),
                ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('WxButton', () {
    testWidgets('shows its label and reports taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: wxTheme(),
          home: Scaffold(
            body: WxButton(label: 'REF', onTap: () => taps++),
          ),
        ),
      );

      expect(find.text('REF'), findsOneWidget);
      await tester.tap(find.text('REF'));
      expect(taps, 1);
    });

    testWidgets('without a handler it is inert rather than missing',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WxButton(label: 'REF')),
        ),
      );

      // A disabled product button still has to be readable — it says which
      // products exist, which is most of what the bar is for.
      expect(find.text('REF'), findsOneWidget);
      await tester.tap(find.text('REF'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an active button is drawn differently from an idle one',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wxTheme(),
          home: Scaffold(
            body: Row(
              children: [
                WxButton(label: 'ON', active: true, onTap: () {}),
                WxButton(label: 'OFF', onTap: () {}),
              ],
            ),
          ),
        ),
      );

      Color? colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;

      expect(colorOf('ON'), Wx.accent);
      expect(colorOf('OFF'), isNot(Wx.accent));
    });

    testWidgets('being unavailable dims an active button without hiding that '
        'it is on', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wxTheme(),
          home: const Scaffold(
            body: Row(
              children: [
                WxButton(label: 'ON', active: true),
                WxButton(label: 'OFF'),
              ],
            ),
          ),
        ),
      );

      Color? colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;

      // Both are disabled, but the armed one must not collapse into looking
      // exactly like the idle one.
      expect(colorOf('OFF'), Wx.textFaint);
      expect(colorOf('ON'), isNot(Wx.textFaint));
    });
  });

  group('WxBar', () {
    testWidgets('fits a desktop window without overflowing', (tester) async {
      await _pumpBar(tester, const Size(1280, 800));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a phone in portrait scrolls instead of overflowing',
        (tester) async {
      await _pumpBar(tester, const Size(360, 740));
      // The bar is a fixed-height strip, so it cannot wrap the way the old
      // toolbar did. Overflowing here is what a plain Row would do, and it
      // paints the yellow-and-black stripe over the chrome.
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the trailing group on screen when space is tight',
        (tester) async {
      await _pumpBar(
        tester,
        const Size(360, 740),
        trailing: const [WxButton(label: 'PINNED', dense: true)],
      );

      // Whatever the leading group does, the tools pinned to the right stay
      // reachable — scrolling to find them would defeat pinning them.
      final bar = tester.getRect(find.byType(WxBar));
      final pinned = tester.getRect(find.text('PINNED'));
      expect(pinned.right, lessThanOrEqualTo(bar.right + 0.5));
      expect(pinned.left, greaterThanOrEqualTo(bar.left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the strip keeps its height whatever it carries',
        (tester) async {
      await _pumpBar(tester, const Size(360, 740));
      expect(tester.getSize(find.byType(WxBar)).height, Wx.barH);
    });
  });

  /// The radar site dots (#42): too small to hit, and too faint to see.
  ///
  /// These assert the two things that were actually wrong, rather than the
  /// exact numbers chosen to fix them — a later redesign is free to move the
  /// sizes and colours, and should still not be free to go back under the
  /// touch minimum or down to a dot nobody can pick out of a dark map.
  group('radar site markers', () {
    test('the tap target clears the touch minimum', () {
      expect(Wx.siteHit, greaterThanOrEqualTo(Wx.minTouch));
    });

    /// The point of the fix: the box you can hit is decoupled from the dot
    /// you can see, because two hundred dots the size of a fingertip would
    /// bury the weather underneath them.
    test('the tap target is bigger than the dot it contains', () {
      expect(Wx.siteDot, lessThan(Wx.siteHit));
    });

    /// Sites are roughly 200-300 km apart, which is around 30 screen pixels
    /// by zoom 4. Much past that and a marker starts taking the taps meant
    /// for its neighbour, which is a different way of being hard to click.
    test('the tap target does not grow into its neighbours', () {
      expect(Wx.siteHit, lessThanOrEqualTo(40.0));
    });

    /// Was `Colors.white24` — white at 24% opacity, under a translucent radar
    /// overlay, on a dark basemap, outdoors at night. Contrast against the
    /// darkest thing it is drawn on is the property that matters, so that is
    /// what is measured.
    test('the dot stands out against the map beneath it', () {
      final dot = Wx.text.computeLuminance();
      final dark = Wx.bg0.computeLuminance();
      final ratio = (dot + 0.05) / (dark + 0.05);
      expect(ratio, greaterThan(4.5),
          reason: 'WCAG AA for non-text is 3:1; a dot at night wants more');
      expect(Wx.text.a, 1.0, reason: 'opaque — 24% white is what broke it');
    });

    /// The selected site has to be tellable from the other two hundred.
    test('the selected site is a different colour from the rest', () {
      expect(Wx.accent, isNot(Wx.text));
    });
  });

  group('pane layouts', () {
    test('each layout knows how many panes it holds', () {
      expect(PaneLayout.single.count, 1);
      expect(PaneLayout.twoAcross.count, 2);
      expect(PaneLayout.twoDown.count, 2);
      expect(PaneLayout.quad.count, 4);
    });

    test('the four-panel preset fills every pane with a distinct product', () {
      expect(panelPreset.length, PaneLayout.quad.count);
      expect(panelPreset.map((p) => p.short).toSet().length, panelPreset.length);
    });

    test('every preset product is one the product menu offers', () {
      final offered = {
        ...l3Products,
        ...l2Products,
        ...derivedProducts,
        mrmsProduct,
      };
      for (final p in [...panelPreset, ...quickProducts, defaultProduct]) {
        expect(offered, contains(p));
      }
    });

    test('tilted products build the mnemonic the archive is keyed by', () {
      // N0B/N1B/N2B/N3B — the tilt digit sits in the middle.
      expect(productRef.code(0), 'N0B');
      expect(productRef.code(3), 'N3B');
      expect(productVel.code(1), 'N1G');
      // A fixed-code product ignores the tilt entirely.
      expect(productStp.code(2), 'DTA');
    });

    test('volume-integrated and mosaic products have no tilt dimension', () {
      expect(productCref.hasTilts, isFalse);
      expect(mrmsProduct.hasTilts, isFalse);
      expect(productRef.hasTilts, isTrue);
    });
  });

  // Grid sizes below are the room left for panes once the two 30pt chrome
  // strips and the 24pt status strip have taken their share.
  group('layouts offered for the room available', () {
    test('a phone in portrait offers two stacked, not two side by side', () {
      const w = 360.0, h = 740 - 84.0;

      expect(PaneLayout.availableIn(w, h),
          [PaneLayout.single, PaneLayout.twoDown]);
      // Splitting 360 points across two columns leaves panes narrower than
      // the colour key that explains them.
      expect(PaneLayout.twoAcross.fitsIn(w, h), isFalse);
      expect(PaneLayout.quad.fitsIn(w, h), isFalse);
    });

    test('a phone in landscape offers two side by side instead', () {
      const w = 800.0, h = 400 - 84.0;

      expect(PaneLayout.availableIn(w, h),
          [PaneLayout.single, PaneLayout.twoAcross]);
      expect(PaneLayout.twoDown.fitsIn(w, h), isFalse);
    });

    test('a tablet takes everything', () {
      expect(PaneLayout.availableIn(600, 960 - 84), PaneLayout.values);
      expect(PaneLayout.availableIn(1024, 768 - 84), PaneLayout.values);
    });

    test('four panes on a phone renders as two rather than as one', () {
      // Keeping the pane count and reorienting beats dropping to a single
      // pane: the user asked for a comparison, and one is still possible.
      expect(
        PaneLayout.bestFor(PaneLayout.quad, 360, 740 - 84),
        PaneLayout.twoDown,
      );
      expect(
        PaneLayout.bestFor(PaneLayout.quad, 800, 400 - 84),
        PaneLayout.twoAcross,
      );
    });

    test('turning a phone swaps the orientation of a two-pane split', () {
      // Portrait cannot do side by side, landscape cannot do stacked.
      expect(
        PaneLayout.bestFor(PaneLayout.twoAcross, 360, 740 - 84),
        PaneLayout.twoDown,
      );
      expect(
        PaneLayout.bestFor(PaneLayout.twoDown, 800, 400 - 84),
        PaneLayout.twoAcross,
      );
    });

    test('a layout that fits is left exactly as chosen', () {
      for (final l in PaneLayout.values) {
        expect(PaneLayout.bestFor(l, 1920, 1080), l);
      }
    });

    test('a window too small for any split still draws one pane', () {
      expect(PaneLayout.bestFor(PaneLayout.quad, 200, 150), PaneLayout.single);
      expect(PaneLayout.availableIn(200, 150), [PaneLayout.single]);
    });
  });
}
