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

  test('with no viewport hook the hand-over stays put', () {
    expect(c.viewport, isNull);
    c.maybeSwitchMosaic(multiPane: false);
    expect(identical(c.product, productRef), isTrue);
  });

  test('a snapshot with nothing on screen returns no path', () {
    expect(c.saveFrameSnapshot(), isNull);
  });
}
