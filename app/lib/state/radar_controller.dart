/// All of the radar screen's state and data orchestration, with no widgets.
///
/// This is the seam between the UI and the engine. The controller owns what
/// is being shown (site, product, tilt, frames, overlays, cursor, replay
/// time) and every call out to `lib/data/` and the Rust bridge; the widget
/// layer above it only reads these fields, calls these methods, and draws.
///
/// Deliberately free of `BuildContext`: anything that needs one — snack
/// bars, navigation, dialogs, the map camera — is either surfaced through
/// [messages] or handed in through the [viewport] and [onMoveMap] hooks. A
/// replacement UI can therefore be written against this class without
/// touching decoding, fetching, or rendering.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import '../data/glm_fetcher.dart';
import '../data/level2_fetcher.dart';
import '../data/level3_fetcher.dart';
import '../data/lightning.dart';
import '../data/locate.dart';
import '../data/mrms_fetcher.dart';
import '../data/nexrad_sites.g.dart';
import '../data/spc_fetcher.dart';
import '../data/user_files.dart';
import '../model/models.dart';
import '../src/rust/api/radar.dart';
// Prefixed alias so engine calls still resolve where a getter on this class
// shares their name (`stormTracks`).
import '../src/rust/api/radar.dart' as engine;

/// What the controller needs to know about the map camera.
///
/// Supplied by the UI through [RadarController.viewport] so the controller
/// never has to import `MapController` or reach for a `MediaQuery`.
class MapViewport {
  /// Currently visible bounds.
  final double north;
  final double south;
  final double east;
  final double west;

  /// Current camera zoom, used to decide the mosaic hand-over.
  final double zoom;

  /// Physical pixels across the map view (logical width x device pixel
  /// ratio). Sets how finely the visible box is re-rendered.
  final double pixelWidth;

  const MapViewport({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
    required this.zoom,
    required this.pixelWidth,
  });
}

/// Pixel box to render, in geographic coordinates.
typedef ViewBox = ({
  double n,
  double s,
  double e,
  double w,
  int width,
  int height,
});

class RadarController extends ChangeNotifier {
  // ------------------------------------------------------------- hooks ----

  /// Reads the live map camera. Set by the UI once the map exists; until it
  /// is set, viewport sharpening and the mosaic hand-over simply don't run.
  MapViewport? Function()? viewport;

  /// Moves the map camera. The controller calls this when picking a site or
  /// jumping to the user's location.
  void Function(LatLng center, double zoom)? onMoveMap;

  final _messages = StreamController<String>.broadcast();

  /// Transient notices for the UI to surface however it likes (a snack bar
  /// today). Errors that should persist on screen go to [error] instead.
  Stream<String> get messages => _messages.stream;

  // ------------------------------------------------------------- state ----

  NexradSite _site = nexradSites.firstWhere((s) => s.icao == 'KTLX');
  Product _product = defaultProduct;
  int _tilt = 0;
  Basemap _basemap = defaultBasemap;
  LatLng? _myLocation;

  /// How many animation frames to load. 1 = just the latest scan (default,
  /// fastest); more enables the loop.
  int _frameCount = 1;

  List<DisplayFrame> _frames = [];
  int _frameIndex = 0;

  /// Storm tracks. Its own overlay, drawn over whatever product is up, so it
  /// works the same on velocity or CC as on reflectivity. The cells are
  /// always found in reflectivity — that is where storms are visible — which
  /// is why this keeps its own pair of frames rather than using [frames].
  bool _tracks = false;
  List<StormTrack> _stormTracks = [];
  List<MesoHit> _mesos = [];
  bool _tracksBusy = false;
  bool _playing = false;
  Timer? _animTimer;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  List<WeatherAlert> _alerts = [];
  List<OutlookArea> _outlook = [];
  List<StormReport> _reports = [];
  bool _showOutlook = false;
  bool _showReports = false;

  /// Which alert categories go on the map. Warnings are what matters in the
  /// moment; watches cover whole counties for hours and would otherwise wash
  /// the map out, so they start off.
  final Set<AlertCategory> _alertLayers = {AlertCategory.warning};

  /// Last alert-fetch failure, surfaced rather than swallowed.
  String? _alertError;

  /// Color key. Cached per product so switching back is instant, and rebuilt
  /// when a palette is imported since that changes the colors on the map.
  bool _showKey = true;
  ColorScale? _keyScale;
  String? _keyFor;
  int _paletteGeneration = 0;
  Timer? _alertTimer;
  final Map<String, Uint8List> _l2Cache = {};

  final _blitz = BlitzortungClient();
  final _glm = GlmClient();
  final List<Strike> _strikes = [];
  LightningSource _lightning = LightningSource.off;
  StreamSubscription<Strike>? _strikeSub;
  StreamSubscription<Strike>? _glmSub;
  Timer? _strikeTimer;
  bool _strikesDirty = false;

  String? _sampleText;
  LatLng? _samplePos;
  Timer? _sampleClear;

  Timer? _viewDebounce;
  int _viewGeneration = 0;

  // Aiming cursor: live value + range/azimuth/height from the radar
  bool _cursor = false;
  LatLng? _cursorPos;
  LatLng? _cursorSite;
  SampleResult? _cursorSample;
  bool _cursorPinned = false;
  bool _cursorBusy = false;
  DateTime _cursorLast = DateTime.fromMillisecondsSinceEpoch(0);

  // Historical replay, measuring tool
  DateTime? _historyTime;
  bool _measuring = false;
  final List<LatLng> _measurePts = [];

  // Future radar (on-device nowcast)
  bool _future = false;
  double _futureMinutes = 30;
  DisplayFrame? _futureFrame;
  bool _futureBusy = false;

  bool _disposed = false;

  // ----------------------------------------------------------- getters ----

  NexradSite get site => _site;
  Product get product => _product;
  int get tilt => _tilt;
  Basemap get basemap => _basemap;
  LatLng? get myLocation => _myLocation;
  int get frameCount => _frameCount;
  List<DisplayFrame> get frames => UnmodifiableListView(_frames);
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;

  bool get tracksEnabled => _tracks;
  List<StormTrack> get stormTracks => UnmodifiableListView(_stormTracks);
  List<MesoHit> get mesos => UnmodifiableListView(_mesos);

  List<WeatherAlert> get alerts => UnmodifiableListView(_alerts);
  List<OutlookArea> get outlook => UnmodifiableListView(_outlook);
  List<StormReport> get reports => UnmodifiableListView(_reports);
  bool get showOutlook => _showOutlook;
  bool get showReports => _showReports;
  Set<AlertCategory> get alertLayers => UnmodifiableSetView(_alertLayers);
  String? get alertError => _alertError;

  bool get showKey => _showKey;
  ColorScale? get keyScale => _keyScale;

  LightningSource get lightning => _lightning;
  bool get showLightning => _lightning.on;
  List<Strike> get strikes => UnmodifiableListView(_strikes);

  String? get sampleText => _sampleText;
  LatLng? get samplePos => _samplePos;

  bool get cursorEnabled => _cursor;
  LatLng? get cursorPos => _cursorPos;
  LatLng? get cursorSite => _cursorSite;
  SampleResult? get cursorSample => _cursorSample;
  bool get cursorPinned => _cursorPinned;

  DateTime? get historyTime => _historyTime;
  bool get measuring => _measuring;
  List<LatLng> get measurePts => UnmodifiableListView(_measurePts);

  bool get futureEnabled => _future;
  double get futureMinutes => _futureMinutes;
  DisplayFrame? get futureFrame => _futureFrame;

  /// Index of the frame actually on screen, clamped so a shrinking loop
  /// can't leave the index past the end.
  int get shownFrame =>
      _frames.isEmpty ? 0 : math.min(_frameIndex, _frames.length - 1);

  /// The frame the map should draw: the nowcast when future radar is on and
  /// has produced one, otherwise the current animation frame.
  DisplayFrame? get displayedFrame => _future && _futureFrame != null
      ? _futureFrame
      : (_frames.isEmpty ? null : _frames[shownFrame]);

  /// Age of the newest loaded scan, or null when nothing is loaded.
  Duration? get frameAge => _frames.isEmpty
      ? null
      : DateTime.now().toUtc().difference(_frames.last.time);

  /// True when the newest scan is old enough to be worth flagging.
  bool get stale => (frameAge?.inMinutes ?? 0) > 20;

  // --------------------------------------------------------- lifecycle ----

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Find where we are, tune to the nearest radar, and load. GPS if
  /// permission is already granted, IP geolocation otherwise; no prompt
  /// here, that belongs to the "my location" button. Falls back to the
  /// default site silently.
  Future<void> start() async {
    _startAnimation();
    unawaited(loadAlerts());
    _alertTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => loadAlerts(),
    );

    final loc = await locate(askPermission: false);
    if (loc != null && !_disposed) {
      _myLocation = loc;
      _site = _nearestSite(loc);
      _notify();
      onMoveMap?.call(loc, 7);
    }
    await loadFrames();
  }

  @override
  void dispose() {
    _disposed = true;
    _animTimer?.cancel();
    _alertTimer?.cancel();
    _strikeTimer?.cancel();
    _viewDebounce?.cancel();
    _sampleClear?.cancel();
    _strikeSub?.cancel();
    _glmSub?.cancel();
    _blitz.stop();
    _glm.stop();
    _messages.close();
    super.dispose();
  }

  // -------------------------------------------------------------- data ----

  Future<void> loadAlerts() async {
    try {
      final alerts = await fetchActiveAlerts();
      if (_disposed) return;
      _alerts = alerts;
      _alertError = null;
      _notify();
      await resolveAlertOutlines();
    } catch (e) {
      // Keep the last good set, but say something. Swallowing this silently
      // is how a broken request looked like "there are no warnings".
      if (_disposed) return;
      _alertError = e.toString();
      _notify();
    }
  }

  /// Build outlines for the county-issued alerts in whichever categories are
  /// switched on. Only those, because resolving every zone nationwide would
  /// be hundreds of requests for shapes nobody asked to see.
  Future<void> resolveAlertOutlines() async {
    final wanted = [
      for (final a in _alerts)
        if (!a.hasPolygon && _alertLayers.contains(a.category)) a,
    ];
    if (wanted.isEmpty) return;
    await resolveZoneOutlines(wanted);
    _notify();
  }

  Future<void> loadOutlook() async {
    if (_outlook.isNotEmpty) return;
    try {
      final o = await fetchOutlook();
      if (_disposed) return;
      _outlook = o;
      _notify();
    } catch (_) {}
  }

  Future<void> loadReports() async {
    if (_reports.isNotEmpty) return;
    try {
      final r = await fetchStormReports();
      if (_disposed) return;
      _reports = r;
      _notify();
    } catch (_) {}
  }

  void _startAnimation() {
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (!_playing || _frames.length < 2) return;
      // Dwell on the newest frame for a few ticks before looping.
      if (_frameIndex >= _frames.length - 1 + 3) {
        _frameIndex = 0;
      } else {
        _frameIndex++;
      }
      _notify();
    });
  }

  Future<void> loadFrames() async {
    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    _notify();
    try {
      final frames = _product.isMrms
          ? await _loadMrmsFrames()
          : _product.isLevel2
              ? await _loadLevel2Frames()
              : await _loadLevel3Frames();
      if (generation != _loadGeneration || _disposed) return;
      for (final f in frames) {
        // Warm the image cache so animation doesn't flicker.
        await _warmImage(f.image);
      }
      if (generation != _loadGeneration || _disposed) return;
      _frames = frames;
      _frameIndex = frames.length - 1;
      _playing = frames.length > 1;
      _loading = false;
      _notify();
      // Sharpen for the current viewport right away.
      unawaited(renderViewport());
      unawaited(updateTracks());
      unawaited(_loadColorKey(frames.isEmpty ? null : frames.last));
      if (_cursor) unawaited(openCursorSession());
    } catch (e) {
      if (generation != _loadGeneration || _disposed) return;
      _loading = false;
      _error = e.toString();
      _notify();
    }
  }

  /// What `precacheImage` does, without needing a `BuildContext`.
  Future<void> _warmImage(ImageProvider provider) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void done() {
      if (!completer.isCompleted) completer.complete();
      stream.removeListener(listener);
    }

    listener = ImageStreamListener(
      (_, _) => done(),
      onError: (_, _) => done(),
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<void> updateTracks() async {
    if (!_tracks || _tracksBusy) return;
    _tracksBusy = true;
    try {
      final keys = await listRecentKeys(
        _site.shortId,
        'NST',
        count: 1,
        before: _historyTime,
      );
      if (keys.isEmpty) {
        if (!_disposed && _tracks) {
          _stormTracks = [];
          _notify();
        }
        return;
      }
      final bytes = Uint8List.fromList(await fetchObject(keys.last));
      final tracks = await engine.stormTracks(data: bytes);

      // Mesocyclones ride along: same overlay, same product family, and the
      // circulation table carries the storm id so the two tie together. A
      // volume with no rotation publishes an empty product, which is an
      // answer rather than a failure.
      var circs = <MesoHit>[];
      try {
        final mdKeys = await listRecentKeys(
          _site.shortId,
          'NMD',
          count: 1,
          before: _historyTime,
        );
        if (mdKeys.isNotEmpty) {
          circs = await mesocyclones(
            data: Uint8List.fromList(await fetchObject(mdKeys.last)),
          );
        }
      } catch (_) {
        // Tracks are still worth showing without rotation data.
      }

      if (_disposed || !_tracks) return;
      _stormTracks = tracks;
      _mesos = circs;
      _notify();
    } catch (_) {
      // Tracks are an extra: a failure here must not disturb the radar. A
      // site with no storms publishes no cells, which is not an error.
      if (!_disposed && _tracks) {
        _stormTracks = [];
        _mesos = [];
        _notify();
      }
    } finally {
      _tracksBusy = false;
    }
  }

  Future<List<DisplayFrame>> _loadLevel3Frames() async {
    final productCode = _product.code(_tilt);
    final keys = await listRecentKeys(
      _site.shortId,
      productCode,
      count: _frameCount,
      before: _historyTime,
    );
    if (keys.isEmpty) {
      throw Exception('no recent $productCode data for ${_site.icao}');
    }
    return Future.wait(keys.map((key) async {
      final bytes = Uint8List.fromList(await fetchObject(key));
      final frame = await renderLevel3Frame(data: bytes, imageSize: 1024);
      return DisplayFrame(
        frame,
        MemoryImage(Uint8List.fromList(frame.png)),
        bytes,
      );
    }));
  }

  /// The national mosaic is one CONUS grid per file; decode covers the whole
  /// country, so the initial render just uses the grid's own bounds.
  Future<List<DisplayFrame>> _loadMrmsFrames() async {
    final keys = await listRecentMosaics(
      count: math.min(_frameCount, 6),
      before: _historyTime,
    );
    if (keys.isEmpty) throw Exception('no recent MRMS mosaics');
    final frames = <DisplayFrame>[];
    for (final key in keys) {
      final bytes = await fetchMosaic(key);
      final frame = await renderMrmsView(
        data: bytes,
        north: 55,
        south: 20,
        east: -60,
        west: -130,
        width: 1400,
        height: 900,
      );
      frames.add(DisplayFrame(
        frame,
        MemoryImage(Uint8List.fromList(frame.png)),
        bytes,
      ));
    }
    return frames;
  }

  /// Level 2 volumes are big (5-15 MB), so cap the loop length and cache the
  /// raw bytes so tilt/moment switches don't re-download.
  Future<List<DisplayFrame>> _loadLevel2Frames() async {
    final count = math.min(_frameCount, 4);
    final keys = await listRecentVolumes(
      _site.icao,
      count: count,
      before: _historyTime,
    );
    if (keys.isEmpty) {
      throw Exception('no recent Level 2 volumes for ${_site.icao}');
    }
    final frames = <DisplayFrame>[];
    for (final key in keys) {
      final bytes = _l2Cache[key] ?? await fetchVolume(key);
      _l2Cache[key] = bytes;
      final frame = await renderLevel2Frame(
        data: bytes,
        moment: _product.l2Moment!,
        elevationIndex: _product.hasTilts ? _tilt : 0,
        imageSize: 1024,
      );
      frames.add(DisplayFrame(
        frame,
        MemoryImage(Uint8List.fromList(frame.png)),
        bytes,
      ));
    }
    while (_l2Cache.length > 6) {
      _l2Cache.remove(_l2Cache.keys.first);
    }
    return frames;
  }

  // ------------------------------------------------------------ cursor ----

  /// Point the cursor at the frame currently on screen. Cheap to call: the
  /// engine keeps the decoded sweep so each aim is just a lookup.
  Future<void> openCursorSession() async {
    if (!_cursor || _frames.isEmpty || _product.isMrms) return;
    final frame = _frames[shownFrame];
    try {
      if (_product.isLevel2) {
        await inspectOpenLevel2(
          data: frame.raw,
          moment: _product.l2Moment!,
          elevationIndex: _product.hasTilts ? _tilt : 0,
        );
      } else {
        await inspectOpenLevel3(data: frame.raw);
      }
      final site = await inspectSite();
      if (_disposed) return;
      _cursorSite = site.length >= 2 ? LatLng(site[0], site[1]) : null;
      _notify();
      // Keep a pinned readout current as frames advance.
      final at = _cursorPos;
      if (at != null) {
        final s = await inspectSample(lat: at.latitude, lon: at.longitude);
        if (_disposed) return;
        _cursorSample = s;
        _notify();
      }
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _notify();
    }
  }

  /// Aim at a point and read the value there. Throttled so a moving pointer
  /// doesn't queue up work.
  ///
  /// [fromTap] pins the cursor so it stays put; while pinned, hovering does
  /// not move it. Releasing a pin is [unpinCursor], which the UI calls when
  /// the tap landed on the pin itself — that hit test needs the map camera,
  /// so it belongs to the widget layer.
  Future<void> aimCursor(LatLng p, {bool fromTap = false}) async {
    if (!_cursor) return;
    if (fromTap) {
      _cursorPinned = true;
    } else if (_cursorPinned) {
      return; // pinned: ignore pointer movement
    }
    _cursorPos = p;
    _notify();
    final now = DateTime.now();
    if (!fromTap &&
        (_cursorBusy || now.difference(_cursorLast).inMilliseconds < 60)) {
      return;
    }
    _cursorBusy = true;
    _cursorLast = now;
    try {
      final s = await inspectSample(lat: p.latitude, lon: p.longitude);
      if (_disposed) return;
      _cursorSample = s;
      _notify();
    } catch (_) {
      // No session yet (product switch in flight); next aim will retry.
    } finally {
      _cursorBusy = false;
    }
  }

  /// Release a pinned cursor, leaving it where it is.
  void unpinCursor() {
    if (!_cursorPinned) return;
    _cursorPinned = false;
    _notify();
  }

  void toggleCursor() {
    _cursor = !_cursor;
    if (!_cursor) {
      _cursorPos = null;
      _cursorSample = null;
      _cursorPinned = false;
    }
    _notify();
    if (_cursor) unawaited(openCursorSession());
  }

  // ---------------------------------------------------------- viewport ----

  /// Visible box expanded slightly, clipped to the data extent, plus the
  /// pixel size to render it at. Null when there is nothing to render or the
  /// data disk is out of view.
  ViewBox? _viewBox() {
    final vp = viewport?.call();
    if (vp == null || _frames.isEmpty || _disposed) return null;

    // Expand by 25% so small pans don't immediately show missing edges.
    final dLat = (vp.north - vp.south) * 0.25;
    final dLon = (vp.east - vp.west) * 0.25;
    var north = vp.north + dLat;
    var south = vp.south - dLat;
    var east = vp.east + dLon;
    var west = vp.west - dLon;

    // Clip to the radar's data disk.
    final d = _frames.first.dataBounds;
    north = math.min(north, d.north);
    south = math.max(south, d.south);
    east = math.min(east, d.east);
    west = math.max(west, d.west);
    if (north <= south || east <= west) return null; // disk not in view

    // Pixel size: match on-screen density, capped to keep renders fast.
    final pxPerLon = vp.pixelWidth / (vp.east - vp.west);
    final width = ((east - west) * pxPerLon).round().clamp(256, 2200);
    // Height follows the Mercator aspect of the box.
    double mercY(double latDeg) {
      final lat = latDeg * math.pi / 180.0;
      return math.log(math.tan(math.pi / 4 + lat / 2));
    }

    final aspect =
        (mercY(north) - mercY(south)) / ((east - west) * math.pi / 180.0);
    final height = (width * aspect).round().clamp(256, 2200);
    return (n: north, s: south, e: east, w: west, width: width, height: height);
  }

  /// Called by the UI on every map gesture. Handles the mosaic hand-over
  /// immediately and debounces the viewport re-render.
  ///
  /// Only the radar image depends on the viewport. Storm tracks are
  /// positioned by azimuth and range from the site, so panning and zooming
  /// cannot change where they are — and refetching on every gesture would be
  /// network for nothing.
  void onMapMoved(double zoom) {
    _maybeSwitchMosaic(zoom);
    _viewDebounce?.cancel();
    _viewDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(renderViewport()),
    );
  }

  /// Zoomed out past a single radar's useful range, hand over to the
  /// national mosaic; zoom back in and the site radar returns. Only the
  /// default reflectivity view participates — an explicitly chosen product
  /// is never swapped out from under the user.
  void _maybeSwitchMosaic(double zoom) {
    if (_loading) return;
    if (zoom < 6.0 && _product == defaultProduct) {
      _product = mrmsProduct;
      _frames = [];
      _notify();
      unawaited(loadFrames());
    } else if (zoom >= 6.5 && _product.isMrms) {
      _product = defaultProduct;
      _frames = [];
      _notify();
      unawaited(loadFrames());
    }
  }

  /// Re-render all loaded frames for the current viewport at (roughly)
  /// screen resolution, so 250 m gates stay sharp when zoomed in.
  Future<void> renderViewport() async {
    if (_frames.isEmpty || _disposed) return;
    // Bumped before the box is worked out, so a gesture that pans the disk
    // out of view still cancels a render already in flight.
    final generation = ++_viewGeneration;
    final box = _viewBox();
    if (box == null) return;
    try {
      final results = await Future.wait(_frames.map((f) async {
        final r = _product.isMrms
            ? await renderMrmsView(
                data: f.raw,
                north: box.n,
                south: box.s,
                east: box.e,
                west: box.w,
                width: box.width,
                height: box.height,
              )
            : _product.isLevel2
                ? await renderLevel2View(
                    data: f.raw,
                    moment: _product.l2Moment!,
                    elevationIndex: _product.hasTilts ? _tilt : 0,
                    north: box.n,
                    south: box.s,
                    east: box.e,
                    west: box.w,
                    width: box.width,
                    height: box.height,
                  )
                : await renderLevel3View(
                    data: f.raw,
                    north: box.n,
                    south: box.s,
                    east: box.e,
                    west: box.w,
                    width: box.width,
                    height: box.height,
                  );
        return MemoryImage(Uint8List.fromList(r.png));
      }));
      if (generation != _viewGeneration || _disposed) return;
      final newBounds = LatLngBounds(
        LatLng(box.n, box.w),
        LatLng(box.s, box.e),
      );
      for (var i = 0; i < _frames.length; i++) {
        await _warmImage(results[i]);
        _frames[i].image = results[i];
        _frames[i].bounds = newBounds;
      }
      if (generation != _viewGeneration || _disposed) return;
      _notify();
      if (_future) unawaited(renderFuture());
    } catch (_) {
      // Viewport sharpening is best-effort; the full-disk render stays up.
    }
  }

  // ------------------------------------------------------------ future ----

  /// Extrapolate the two most recent frames forward on-device.
  Future<void> renderFuture() async {
    if (!_future || _futureBusy) return;
    if (_product.isLevel2) {
      _error = 'Future radar needs a Level 3 or mosaic product';
      _notify();
      return;
    }
    if (_frames.length < 2) {
      // Need a previous scan to measure motion against.
      _frameCount = math.max(_frameCount, 4);
      _notify();
      await loadFrames();
      if (_frames.length < 2 || !_future) return;
    }
    final box = _viewBox();
    if (box == null) return;
    _futureBusy = true;
    try {
      final r = await nowcastView(
        prev: _frames[_frames.length - 2].raw,
        latest: _frames.last.raw,
        source: _product.isMrms ? 'MRMS' : 'L3',
        minutes: _futureMinutes,
        north: box.n,
        south: box.s,
        east: box.e,
        west: box.w,
        width: box.width,
        height: box.height,
      );
      if (_disposed || !_future) return;
      final img = MemoryImage(Uint8List.fromList(r.png));
      await _warmImage(img);
      if (_disposed || !_future) return;
      _futureFrame = DisplayFrame(r, img, Uint8List(0));
      _notify();
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _notify();
    } finally {
      _futureBusy = false;
    }
  }

  void toggleFuture() {
    _future = !_future;
    if (!_future) _futureFrame = null;
    _notify();
    if (_future) unawaited(renderFuture());
  }

  /// Drag the forecast slider. Cheap — no render until [commitFutureMinutes].
  void setFutureMinutes(double minutes) {
    if (_futureMinutes == minutes) return;
    _futureMinutes = minutes;
    _notify();
  }

  /// Slider released: render at the chosen lead time.
  void commitFutureMinutes() => unawaited(renderFuture());

  // ------------------------------------------------------------- sites ----

  void selectSite(NexradSite site, {bool moveMap = false}) {
    if (site.icao == _site.icao) return;
    _site = site;
    _frames = [];
    _notify();
    if (moveMap) {
      onMoveMap?.call(LatLng(site.lat, site.lon), _currentZoom());
    }
    unawaited(loadFrames());
  }

  double _currentZoom() => viewport?.call()?.zoom ?? 7;

  NexradSite _nearestSite(LatLng p) {
    NexradSite best = nexradSites.first;
    double bestD = double.infinity;
    for (final s in nexradSites) {
      if (s.isTdwr) continue; // TDWR products come in a later phase
      final d = squaredDistance(p.latitude, p.longitude, s.lat, s.lon);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  /// Re-locate and re-tune. Always re-asks rather than reusing the startup
  /// fix: the button is what triggers the permission prompt, and a stale
  /// position is the thing the user is trying to correct.
  Future<void> goToMyLocation() async {
    final result = await locateDetailed();
    final loc = result.position;
    if (_disposed) return;
    if (loc == null) {
      // Silence here reads as a dead button, so say what went wrong.
      _messages.add(result.message);
      return;
    }
    _myLocation = loc;
    _notify();
    onMoveMap?.call(loc, result.precise ? 8 : 7);
    final nearest = _nearestSite(loc);
    if (nearest.icao != _site.icao) selectSite(nearest);
  }

  // --------------------------------------------------------- lightning ----

  void setLightning(LightningSource src) {
    _lightning = src;
    _notify();

    if (src.usesBlitzortung) {
      _blitz.start();
      _strikeSub ??= _blitz.strikes.listen((s) {
        _strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _blitz.stop();
    }
    if (src.usesGlm) {
      _glm.start();
      _glmSub ??= _glm.strikes.listen((s) {
        _strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _glm.stop();
    }

    if (src.on) {
      // Repaint on a slow tick instead of per strike (tens per second).
      _strikeTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        final cutoff = DateTime.now().toUtc().subtract(
              const Duration(minutes: 20),
            );
        final before = _strikes.length;
        _strikes.removeWhere((s) => s.time.isBefore(cutoff));
        if (_strikes.length > 8000) {
          _strikes.removeRange(0, _strikes.length - 8000);
        }
        if (_strikesDirty || _strikes.length != before) {
          _strikesDirty = false;
          _notify();
        }
      });
    } else {
      _strikeTimer?.cancel();
      _strikeTimer = null;
      _strikes.clear();
    }
  }

  // ------------------------------------------------------------- 3D/L2 ----

  /// Fetch the Level 2 volume the 3D view should open on, at the moment
  /// currently being shown. The UI does the navigating.
  ///
  /// `before` matters: without it replay showed the chosen time on the map
  /// while 3D silently jumped to now, which is worse than not replaying at
  /// all because nothing on screen says the two disagree.
  Future<Uint8List?> prepareVolume() async {
    _loading = true;
    _notify();
    try {
      final keys = await listRecentVolumes(
        _site.icao,
        count: 1,
        before: _historyTime,
      );
      if (keys.isEmpty) throw Exception('no volume for ${_site.icao}');
      final bytes = _l2Cache[keys.last] ?? await fetchVolume(keys.last);
      _l2Cache[keys.last] = bytes;
      if (_disposed) return null;
      _loading = false;
      _notify();
      return bytes;
    } catch (e) {
      if (_disposed) return null;
      _loading = false;
      _error = e.toString();
      _notify();
      return null;
    }
  }

  // --------------------------------------------------------- inspector ----

  Future<void> inspect(LatLng p) async {
    if (_frames.isEmpty || _product.isMrms) return;
    final frame = _frames[shownFrame];
    try {
      final s = _product.isLevel2
          ? await sampleLevel2(
              data: frame.raw,
              moment: _product.l2Moment!,
              elevationIndex: _product.hasTilts ? _tilt : 0,
              lat: p.latitude,
              lon: p.longitude,
            )
          : await sampleLevel3(
              data: frame.raw,
              lat: p.latitude,
              lon: p.longitude,
            );
      if (_disposed) return;
      final beamKft = s.beamHeightM * 3.28084 / 1000.0;
      final valueText = s.rangeFolded
          ? 'RF'
          : s.value == null
              ? 'no data'
              : '${s.value!.toStringAsFixed(1)} ${s.unit}'.trim();
      _samplePos = p;
      _sampleText = s.distanceKm <= 0
          ? 'outside radar coverage'
          : '$valueText  ·  ${s.distanceKm.toStringAsFixed(0)} km'
              '  ·  beam ${beamKft.toStringAsFixed(1)} kft';
      _notify();
      _sampleClear?.cancel();
      _sampleClear = Timer(const Duration(seconds: 8), () {
        if (_disposed) return;
        _sampleText = null;
        _samplePos = null;
        _notify();
      });
    } catch (_) {
      // Sampling is best-effort.
    }
  }

  // --------------------------------------------------------- color key ----

  /// Fetch the color scale for whatever is on screen. Keyed by product plus
  /// palette generation so an imported `.pal` refreshes the key too.
  Future<void> _loadColorKey(DisplayFrame? frame) async {
    final id = '${_product.short}|$_paletteGeneration';
    if (_keyFor == id) return;
    try {
      final scale = await colorScale(
        productCode: _product.isLevel2 || _product.isMrms
            ? 0
            : (frame?.meta.productCode ?? 0),
        moment: _product.l2Moment ?? '',
      );
      if (_disposed) return;
      _keyScale = scale;
      _keyFor = id;
      _notify();
    } catch (_) {
      // The map is still readable without a key.
    }
  }

  /// Apply a `.pal` file, or pass an empty path to clear back to the
  /// built-ins.
  Future<void> applyPalette(String path) async {
    try {
      if (path.isEmpty) {
        await resetPalettes();
      } else {
        final kind = await installPalette(text: File(path).readAsStringSync());
        if (_disposed) return;
        _messages.add('Palette applied to $kind');
      }
      _futureFrame = null;
      _paletteGeneration++;
      await loadFrames();
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _notify();
    }
  }

  // ------------------------------------------------------- simple flips ----

  void setProduct(Product p) {
    if (identical(p, _product)) return;
    _product = p;
    _frames = [];
    _notify();
    unawaited(loadFrames());
  }

  void setTilt(int t) {
    if (t == _tilt) return;
    _tilt = t;
    _frames = [];
    _notify();
    unawaited(loadFrames());
  }

  void setBasemap(Basemap b) {
    if (identical(b, _basemap)) return;
    _basemap = b;
    _notify();
  }

  void setFrameCount(int n) {
    if (n == _frameCount) return;
    _frameCount = n;
    _notify();
    unawaited(loadFrames());
  }

  void togglePlaying() {
    _playing = !_playing;
    _notify();
  }

  void toggleTracks() {
    _tracks = !_tracks;
    if (!_tracks) {
      _stormTracks = [];
      _mesos = [];
    }
    _notify();
    if (_tracks) unawaited(updateTracks());
  }

  void toggleColorKey() {
    _showKey = !_showKey;
    _notify();
  }

  void toggleOutlook() {
    _showOutlook = !_showOutlook;
    _notify();
    if (_showOutlook) unawaited(loadOutlook());
  }

  void toggleReports() {
    _showReports = !_showReports;
    _notify();
    if (_showReports) unawaited(loadReports());
  }

  void toggleAlertCategory(AlertCategory cat) {
    if (!_alertLayers.remove(cat)) _alertLayers.add(cat);
    _notify();
    unawaited(resolveAlertOutlines());
  }

  void toggleMeasuring() {
    _measuring = !_measuring;
    _measurePts.clear();
    _notify();
  }

  void addMeasurePoint(LatLng p) {
    if (_measurePts.length >= 2) _measurePts.clear();
    _measurePts.add(p);
    _notify();
  }

  /// Jump the whole app to a past moment, or pass null to return to live.
  /// The UI owns the date/time pickers; this just applies the result.
  void setHistoryTime(DateTime? when) {
    _historyTime = when;
    _frames = [];
    if (when != null) _l2Cache.clear();
    _notify();
    unawaited(loadFrames());
  }

  /// Write the current radar image to the user's pictures folder.
  Future<void> saveCurrentSnapshot() async {
    final frame = displayedFrame;
    if (frame == null) return;
    try {
      final f = saveSnapshot(
        Uint8List.fromList(frame.meta.png),
        '${_product.isMrms ? 'MRMS' : _site.icao}_${_product.short}'
            .replaceAll(' ', ''),
      );
      if (_disposed) return;
      _messages.add('Saved ${f.path}');
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _notify();
    }
  }
}
