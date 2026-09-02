/// Tests for a pane's state machine, with no widget tree at all.
///
/// That is the point of the split: before [PaneController] existed, every one
/// of these needed `pumpWidget` and a live map, because the state lived in a
/// `State`. Now the pane's logic can be driven directly.
///
/// Kept off the network — anything that reaches `loadFrames` (setProduct,
/// setTilt, setFrameCount, syncTo, toggleTracks, toggleFuture) talks to NOAA,
/// so what is covered here is the surrounding state machine.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/data/nexrad_sites.g.dart';
import 'package:radar_app/state/pane_controller.dart';
import 'package:radar_app/ui/pane_models.dart';
import 'package:radar_app/ui/workspace_state.dart';

void main() {
  late WorkspaceState shared;
  late PaneController c;
  var notifications = 0;
  var changed = 0;

  setUp(() {
    shared = WorkspaceState();
    c = PaneController(
      paneId: 0,
      shared: shared,
      site: nexradSites.firstWhere((s) => s.icao == 'KTLX'),
      product: productRef,
      tilt: 0,
    );
    notifications = 0;
    changed = 0;
    c.addListener(() => notifications++);
    c.onChanged = () => changed++;
  });

  tearDown(() {
    c.dispose();
    shared.dispose();
  });

  test('opens on what it was constructed with', () {
    expect(c.site.icao, 'KTLX');
    expect(identical(c.product, productRef), isTrue);
    expect(c.tilt, 0);
    expect(c.frames, isEmpty);
    expect(c.loading, isFalse);
    expect(c.error, isNull);
  });

  group('auto refresh', () {
    /// The refresh clock reaches every pane, including ones still waiting for
    /// geolocation to settle. Those have no frames and no error, and firing a
    /// load into them would fetch the fallback site's data only to throw it
    /// away when the real site arrives — invariant 11, from the other side.
    test('a pane that has never loaded is left alone', () async {
      expect(c.frames, isEmpty);
      expect(c.error, isNull);
      await c.refreshForNewData();
      expect(c.loading, isFalse, reason: 'must not have started a fetch');
      expect(c.frames, isEmpty);
      expect(c.error, isNull);
    });

    // The replay guard (`historyTime != null`) is deliberately not tested
    // here. With no frames loaded the later "never loaded" guard returns
    // early too, so such a test passes whether or not the replay guard
    // exists — it would assert nothing. Reaching it honestly needs a pane
    // with frames, which needs the network.

    /// The clock keeps ticking after a pane is gone; disposal has to be a
    /// hard stop rather than a load that lands on a dead controller.
    test('a disposed pane does not refresh', () async {
      final gone = PaneController(
        paneId: 3,
        shared: shared,
        site: nexradSites.firstWhere((s) => s.icao == 'KTLX'),
        product: productRef,
        tilt: 0,
      );
      gone.dispose();
      await gone.refreshForNewData();
      expect(gone.loading, isFalse);
    });
  });

  /// One clock for the workspace, not one per pane — four panes each running
  /// their own would drift apart and stagger their reloads.
  test('the workspace owns the refresh clock', () {
    expect(WorkspaceState.radarRefreshInterval.inSeconds, greaterThan(0));
    expect(
      WorkspaceState.radarRefreshInterval,
      lessThan(staleAfter),
      reason: 'a pane must be able to refresh before it is called stale',
    );
  });

  test('nothing is on by default', () {
    expect(c.cursorOn, isFalse);
    expect(c.tracksOn, isFalse);
    expect(c.futureOn, isFalse);
    expect(c.measuringOn, isFalse);
    expect(c.isolated, isFalse);
  });

  test('no frames means no displayed frame, no time and not stale', () {
    expect(c.displayFrame, isNull);
    expect(c.frameTime, isNull);
    expect(c.dataAge, isNull);
    expect(c.isStale, isFalse);
    expect(c.shownFrame, 0);
    expect(c.elevationDeg, isNull);
  });

  test('collections handed out are read-only views', () {
    expect(c.frames.clear, throwsUnsupportedError);
    expect(c.measurePts.clear, throwsUnsupportedError);
    expect(c.stormTracks.clear, throwsUnsupportedError);
    expect(c.mesos.clear, throwsUnsupportedError);
  });

  test('re-selecting the product already shown does nothing', () {
    c.setProduct(productRef);
    expect(notifications, 0);
    expect(changed, 0);
  });

  test('re-selecting the current tilt does nothing', () {
    c.setTilt(0);
    expect(notifications, 0);
  });

  test('re-selecting the current site does nothing', () {
    c.selectSite(nexradSites.firstWhere((s) => s.icao == 'KTLX'));
    expect(notifications, 0);
  });

  group('measuring', () {
    test('collects two points then starts over on the third', () {
      c.toggleMeasure();
      expect(c.measuringOn, isTrue);
      c.addMeasurePoint(const LatLng(35, -97));
      c.addMeasurePoint(const LatLng(36, -98));
      expect(c.measurePts, hasLength(2));
      c.addMeasurePoint(const LatLng(37, -99));
      expect(c.measurePts, hasLength(1));
      expect(c.measurePts.single.latitude, 37);
    });

    test('switching the tool off clears the points', () {
      c.toggleMeasure();
      c.addMeasurePoint(const LatLng(35, -97));
      c.toggleMeasure();
      expect(c.measuringOn, isFalse);
      expect(c.measurePts, isEmpty);
    });
  });

  group('cursor', () {
    test('aiming while off does nothing', () async {
      await c.aimCursor(const LatLng(35, -97));
      expect(c.cursorPos, isNull);
    });

    test('switching off clears the readout and the pin', () {
      c.toggleCursor();
      expect(c.cursorOn, isTrue);
      c.toggleCursor();
      expect(c.cursorOn, isFalse);
      expect(c.cursorPos, isNull);
      expect(c.cursorSample, isNull);
      expect(c.cursorPinned, isFalse);
    });

    test('unpinning an unpinned cursor is a no-op', () {
      final before = notifications;
      c.unpinCursor();
      expect(notifications, before);
    });

    /// The engine session is opened per pane and read back by handle, so a
    /// pane with no frames must not open one at all — the generation guard in
    /// [PaneController.openCursorSession] counts on this early return, and
    /// without it a pane would sample a sweep it never opened.
    test('opening a session with nothing loaded does nothing', () async {
      c.toggleCursor();
      await c.openCursorSession();
      expect(c.frames, isEmpty);
      expect(c.cursorSample, isNull);
      expect(c.cursorSite, isNull);
      expect(c.error, isNull);
    });

    /// A closing pane hands its sweep back to the engine, so dispose now runs
    /// down the cursor session as well as the timers.
    test('disposing with the cursor on closes cleanly', () {
      final closing = PaneController(
        paneId: 2,
        shared: shared,
        site: nexradSites.firstWhere((s) => s.icao == 'KTLX'),
        product: productRef,
        tilt: 0,
      );
      closing.toggleCursor();
      expect(closing.cursorOn, isTrue);
      expect(closing.dispose, returnsNormally);
    });

    /// Two panes each own their cursor. This used to be true of the Dart state
    /// and false of the engine underneath it, which is the whole point of the
    /// per-pane session handle: switching the cursor on in a second pane took
    /// over the first pane's readout, so a reflectivity pane started showing
    /// velocity numbers under a reflectivity label.
    test('one pane switching its cursor on leaves the other alone', () {
      final other = PaneController(
        paneId: 1,
        shared: shared,
        site: nexradSites.firstWhere((s) => s.icao == 'KFWS'),
        product: productVel,
        tilt: 0,
      );
      addTearDown(other.dispose);

      c.toggleCursor();
      expect(c.cursorOn, isTrue);
      expect(other.cursorOn, isFalse);

      other.toggleCursor();
      expect(c.cursorOn, isTrue, reason: 'still on in the first pane');
      expect(other.cursorOn, isTrue);

      other.toggleCursor();
      expect(other.cursorOn, isFalse);
      expect(c.cursorOn, isTrue, reason: 'closing one must not close the other');
    });
  });

  group('clocks', () {
    test('a linked pane reads the shared clock', () {
      expect(c.isolated, isFalse);
      shared.setFrameCount(8);
      expect(c.frameCount, 8);
      expect(c.playing, shared.playing);
      expect(c.loopLength, shared.loopLength);
    });

    test('isolating carries the shared settings across', () {
      shared.setFrameCount(8);
      final wasPlaying = shared.playing;
      c.toggleIsolate();
      expect(c.isolated, isTrue);
      expect(c.frameCount, 8);
      expect(c.playing, wasPlaying);
    });

    test('an isolated pane stops following the shared clock', () {
      c.toggleIsolate();
      final mine = c.frameCount;
      shared.setFrameCount(12);
      expect(c.frameCount, mine, reason: 'isolated pane keeps its own count');
    });

    test('an isolated loop is only as long as the frames it holds', () {
      c.toggleIsolate();
      expect(c.loopLength, 0);
    });
  });

  group('future radar', () {
    test('the lead time slider does not notify on the same value', () {
      c.setFutureMinutes(45);
      expect(c.futureMinutes, 45);
      final before = notifications;
      c.setFutureMinutes(45);
      expect(notifications, before);
    });
  });

  test('the mosaic hand-over is off in a multi-pane layout', () {
    // No viewport hook either, so this must simply do nothing rather than
    // reach for a camera that is not there.
    c.maybeSwitchMosaic(multiPane: true);
    expect(identical(c.product, productRef), isTrue);
  });

  test('the hand-over reads zoom from a pane that has no width yet', () {
    // Pins the contract the widget's hook relies on: deciding the hand-over
    // must not need a pane width, because only rendering does — and that
    // checks for itself. Not a regression test for the widget; this drives
    // the controller directly and cannot see `_readViewport`.
    c.viewport = () => const PaneViewport(
          north: 36,
          south: 34,
          east: -96,
          west: -98,
          zoom: 5.0,
          pixelWidth: 0,
        );
    c.maybeSwitchMosaic(multiPane: false);
    expect(c.product.isMrms, isTrue);
  });

  test('with no viewport hook the hand-over stays put', () {
    expect(c.viewport, isNull);
    c.maybeSwitchMosaic(multiPane: false);
    expect(identical(c.product, productRef), isTrue);
  });

  test('a snapshot with nothing on screen returns no path', () {
    expect(c.saveFrameSnapshot(), isNull);
  });
}
