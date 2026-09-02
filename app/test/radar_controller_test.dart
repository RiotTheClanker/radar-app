/// Controller tests that stay off the network.
///
/// Anything that calls `loadFrames` (setProduct, setTilt, setFrameCount,
/// setHistoryTime, toggleTracks, toggleOutlook, toggleReports) reaches NOAA,
/// so this covers the state machine around those instead: the toggles that
/// are pure, the derived getters, and the notification contract the UI is
/// built on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/data/alerts_fetcher.dart';
import 'package:radar_app/model/models.dart';
import 'package:radar_app/state/radar_controller.dart';

void main() {
  late RadarController c;
  var notifications = 0;

  setUp(() {
    c = RadarController();
    notifications = 0;
    c.addListener(() => notifications++);
  });

  tearDown(() => c.dispose());

  test('opens on a real site, the default product and the dark basemap', () {
    expect(c.site.icao, 'KTLX');
    expect(identical(c.product, defaultProduct), isTrue);
    expect(identical(c.basemap, defaultBasemap), isTrue);
    expect(c.frames, isEmpty);
    expect(c.loading, isFalse);
    expect(c.error, isNull);
  });

  test('starts with warnings drawn and nothing else', () {
    expect(c.alertLayers, {AlertCategory.warning});
    expect(c.showOutlook, isFalse);
    expect(c.showReports, isFalse);
    expect(c.lightning, LightningSource.off);
    expect(c.showLightning, isFalse);
  });

  test('the colour key starts on and toggles', () {
    expect(c.showKey, isTrue);
    c.toggleColorKey();
    expect(c.showKey, isFalse);
    expect(notifications, 1);
  });

  test('collections handed to the UI are read-only views', () {
    expect(c.frames.clear, throwsUnsupportedError);
    expect(c.measurePts.clear, throwsUnsupportedError);
    expect(() => c.alertLayers.add(AlertCategory.warning),
        throwsUnsupportedError);
  });

  group('measuring', () {
    test('collects two points then starts over on the third', () {
      c.toggleMeasuring();
      expect(c.measuring, isTrue);
      c.addMeasurePoint(const LatLng(35, -97));
      c.addMeasurePoint(const LatLng(36, -98));
      expect(c.measurePts, hasLength(2));
      c.addMeasurePoint(const LatLng(37, -99));
      expect(c.measurePts, hasLength(1));
      expect(c.measurePts.single.latitude, 37);
    });

    test('switching the tool off clears the points', () {
      c.toggleMeasuring();
      c.addMeasurePoint(const LatLng(35, -97));
      c.toggleMeasuring();
      expect(c.measuring, isFalse);
      expect(c.measurePts, isEmpty);
    });
  });

  group('cursor', () {
    test('is off by default and aiming while off does nothing', () async {
      expect(c.cursorEnabled, isFalse);
      await c.aimCursor(const LatLng(35, -97));
      expect(c.cursorPos, isNull);
    });

    test('switching off clears the readout and the pin', () {
      c.toggleCursor();
      expect(c.cursorEnabled, isTrue);
      c.toggleCursor();
      expect(c.cursorEnabled, isFalse);
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

  group('future radar', () {
    test('toggling on and off drops the nowcast frame', () {
      expect(c.futureEnabled, isFalse);
      c.toggleFuture();
      expect(c.futureEnabled, isTrue);
      c.toggleFuture();
      expect(c.futureEnabled, isFalse);
      expect(c.futureFrame, isNull);
    });

    test('the lead time slider does not re-render until released', () {
      c.setFutureMinutes(45);
      expect(c.futureMinutes, 45);
      final before = notifications;
      c.setFutureMinutes(45); // same value
      expect(notifications, before);
    });
  });

  test('setting the same basemap does not notify', () {
    c.setBasemap(basemaps[2]);
    expect(identical(c.basemap, basemaps[2]), isTrue);
    final before = notifications;
    c.setBasemap(basemaps[2]);
    expect(notifications, before);
  });

  group('derived getters', () {
    test('no frames means no displayed frame and no age', () {
      expect(c.displayedFrame, isNull);
      expect(c.frameAge, isNull);
      expect(c.stale, isFalse);
      expect(c.shownFrame, 0);
    });
  });

  test('viewport hook is optional — nothing throws without a map', () {
    expect(c.viewport, isNull);
    expect(() => c.onMapMoved(7.0), returnsNormally);
  });

  test('messages is a broadcast stream so the UI can attach late', () {
    expect(c.messages.isBroadcast, isTrue);
  });

  test('a fresh controller disposes cleanly without ever being started', () {
    final d = RadarController();
    expect(d.dispose, returnsNormally);
  });
}
