import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/data/nexrad_sites.g.dart';
import 'package:radar_app/ui/pane_models.dart';
import 'package:radar_app/ui/radar_pane.dart';
import 'package:radar_app/ui/workspace_state.dart';
import 'package:radar_app/ui/wx_theme.dart';

/// Runs [body] against a pane with no data behind it.
///
/// `autoLoad: false` is what the workspace passes before geolocation has
/// settled, and it is what keeps this off the network — isolation is a
/// question about the camera, not about frames.
///
/// The shared state is disposed inside the body rather than through
/// `addTearDown`, because it owns the alert poll and the animation clock and
/// the test binding checks for pending timers before teardown runs.
Future<void> _withPane(
  WidgetTester tester,
  Future<void> Function(RadarPaneState pane) body, {
  void Function(int paneId, LatLng center, double zoom)? onCameraMoved,
  VoidCallback? onIsolateToggled,
}) async {
  final shared = WorkspaceState();
  try {
    final key = GlobalKey<RadarPaneState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: wxTheme(),
        home: Scaffold(
          body: RadarPane(
            key: key,
            paneId: 0,
            shared: shared,
            initialSite: nexradSites.firstWhere((s) => s.icao == 'KTLX'),
            initialProduct: productRef,
            focused: true,
            showHeader: true,
            autoLoad: false,
            onFocus: () {},
            onChanged: () {},
            onCameraMoved: onCameraMoved ?? (_, _, _) {},
            onSitePicked: (_) {},
            onIsolateToggled: onIsolateToggled ?? () {},
          ),
        ),
      ),
    );
    // Let the map attach so it has a camera to report.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await body(key.currentState!);
  } finally {
    shared.dispose();
  }
}

const _elsewhere = LatLng(41.5, -99.5);

void main() {
  testWidgets('a pane in the group follows a linked pan', (tester) async {
    await _withPane(tester, (pane) async {
      expect(pane.isolated, isFalse);

      pane.applyCamera(_elsewhere, 9);
      await tester.pump();

      final cam = pane.cameraOrNull!;
      expect(cam.center.latitude, closeTo(_elsewhere.latitude, 1e-6));
      expect(cam.zoom, closeTo(9, 1e-6));
    });
  });

  testWidgets('an isolated pane ignores another pane panning', (tester) async {
    await _withPane(tester, (pane) async {
      final before = pane.cameraOrNull!;

      pane.toggleIsolate();
      await tester.pump();
      expect(pane.isolated, isTrue);

      pane.applyCamera(_elsewhere, 9);
      await tester.pump();

      // This is the whole point: park a pane on a second storm and work the
      // others around it.
      final after = pane.cameraOrNull!;
      expect(after.center.latitude, closeTo(before.center.latitude, 1e-6));
      expect(after.center.longitude, closeTo(before.center.longitude, 1e-6));
      expect(after.zoom, closeTo(before.zoom, 1e-6));
    });
  });

  testWidgets('an isolated pane still takes an explicit command', (tester) async {
    await _withPane(tester, (pane) async {
      pane.toggleIsolate();
      await tester.pump();

      // "My location" and zoom-to-alert are buttons the user just pressed. A
      // control that silently does nothing reads as broken.
      pane.applyCamera(_elsewhere, 9, force: true);
      await tester.pump();

      expect(
        pane.cameraOrNull!.center.latitude,
        closeTo(_elsewhere.latitude, 1e-6),
      );
    });
  });

  testWidgets('an isolated pane follows an explicit radar change', (tester) async {
    await _withPane(tester, (pane) async {
      pane.toggleIsolate();
      await tester.pump();

      final fws = nexradSites.firstWhere((s) => s.icao == 'KFWS');
      pane.selectSite(fws, moveMap: true);
      await tester.pump();

      // Holding the old framing left the pane pointed at ground the new
      // radar cannot see, so it went blank — which reads as the pane having
      // failed to switch at all.
      expect(pane.site.icao, 'KFWS');
      expect(pane.cameraOrNull!.center.latitude, closeTo(fws.lat, 1e-4));
      expect(pane.cameraOrNull!.center.longitude, closeTo(fws.lon, 1e-4));
    });
  });

  testWidgets('an isolated pane sits still for a site change that does not '
      'move the map', (tester) async {
    await _withPane(tester, (pane) async {
      pane.toggleIsolate();
      await tester.pump();
      final before = pane.cameraOrNull!;

      // Startup settles the site this way once geolocation resolves; there
      // is no explicit command behind it, so nothing should jump.
      pane.selectSite(nexradSites.firstWhere((s) => s.icao == 'KFWS'));
      await tester.pump();

      expect(pane.site.icao, 'KFWS');
      expect(
        pane.cameraOrNull!.center.latitude,
        closeTo(before.center.latitude, 1e-6),
      );
    });
  });

  testWidgets('an isolated pane stops broadcasting its own moves',
      (tester) async {
    var broadcasts = 0;
    await _withPane(
      tester,
      (pane) async {
        await tester.drag(find.byType(RadarPane), const Offset(-60, -40));
        await tester.pump();
        expect(broadcasts, greaterThan(0),
            reason: 'a pane in the group leads the others');

        pane.toggleIsolate();
        await tester.pump();
        final quiet = broadcasts;

        await tester.drag(find.byType(RadarPane), const Offset(-60, -40));
        await tester.pump();

        // Isolating detaches in both directions — a parked pane neither
        // follows nor drags everyone else along with it.
        expect(broadcasts, quiet);
      },
      onCameraMoved: (_, _, _) => broadcasts++,
    );
  });

  testWidgets('the header shows whether the pane is in the group',
      (tester) async {
    await _withPane(tester, (pane) async {
      // Link/link-off rather than a padlock: nothing is being held shut,
      // the pane is simply in or out of the linked group.
      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.link_off), findsNothing);

      pane.toggleIsolate();
      await tester.pump();

      expect(find.byIcon(Icons.link_off), findsOneWidget);
      expect(find.byIcon(Icons.link), findsNothing);
    });
  });

  testWidgets('the header button reports the press rather than acting alone',
      (tester) async {
    var presses = 0;
    await _withPane(
      tester,
      (pane) async {
        await tester.tap(find.byIcon(Icons.link));
        await tester.pump();

        // The workspace owns the toggle: rejoining the group means adopting
        // the group's site, tilt and view, and the pane cannot know any of
        // that on its own.
        expect(presses, 1);
        expect(pane.isolated, isFalse);
      },
      onIsolateToggled: () => presses++,
    );
  });
}
