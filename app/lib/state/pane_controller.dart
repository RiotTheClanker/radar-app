/// One radar pane's state and data orchestration, with no widgets.
///
/// [WorkspaceState] owns what is true of the whole workspace — alerts,
/// lightning, the SPC layers, the basemap, replay time and the animation
/// clock. This owns what is true of one pane: its site, product, tilt,
/// frames, cursor, tracks and nowcast, and every call out to `lib/data/` and
/// the Rust bridge that those need.
///
/// Deliberately free of `BuildContext`. What it cannot see for itself — the
/// map camera, the pane's size on screen — arrives through [viewport];
/// camera moves go out through [onMoveMap]. That is what lets the pane's
/// chrome be redrawn, or replaced outright, without touching any of the
/// fetching, decoding or rendering below.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/level2_fetcher.dart';
import '../data/level3_fetcher.dart';
import '../data/mrms_fetcher.dart';
import '../data/nexrad_sites.g.dart';
import '../data/user_files.dart';
import '../src/rust/api/radar.dart';
import '../src/rust/api/radar.dart' as engine;
import '../ui/pane_models.dart';
import '../ui/workspace_state.dart';

/// What the controller needs to know about the pane's map.
///
/// Supplied by the widget through [PaneController.viewport], so the
/// controller never has to import `MapController` or reach for a
/// `MediaQuery`.
class PaneViewport {
  /// Currently visible bounds.
  final double north;
  final double south;
  final double east;
  final double west;

  /// Current camera zoom, used to decide the mosaic hand-over.
  final double zoom;

  /// Physical pixels across *this pane* (its logical width x the device
  /// pixel ratio) — not the window's. Four panes at a quarter of the area
  /// each therefore ask for a quarter of the pixels.
  final double pixelWidth;

  const PaneViewport({
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

class PaneController extends ChangeNotifier {
  PaneController({
    required this.paneId,
    required this.shared,
    required NexradSite site,
    required RadarProduct product,
    required int tilt,
  })  // Initializing formals cannot be used here: a named parameter may not
      // start with an underscore, and these fields are private because they
      // are mutable state with public getters.
      // ignore: prefer_initializing_formals
      : _site = site,
        // ignore: prefer_initializing_formals
        _product = product,
        // ignore: prefer_initializing_formals
        _tilt = tilt;

  /// Stable index within the workspace, used to key this pane's contribution
  /// to the shared animation clock.
  final int paneId;

  /// State shared with every other pane. Read for replay time, the clock,
  /// the palette generation and the request caches; told about this pane's
  /// loop length so the shared loop is as long as its longest pane.
  final WorkspaceState shared;

  // ------------------------------------------------------------- hooks ----

  /// Reads the live map camera and the pane's size. Set by the widget once
  /// the map is attached; until then viewport sharpening, the nowcast and
  /// the mosaic hand-over simply do not run.
  PaneViewport? Function()? viewport;

  /// Moves this pane's camera.
  void Function(LatLng center, double zoom)? onMoveMap;

  /// Something the workspace toolbar displays changed — product, tilt, site,
  /// frame time, load state.
  VoidCallback? onChanged;

  // ------------------------------------------------------------- state ----

  NexradSite _site;
  RadarProduct _product;
  int _tilt;

  List<DisplayFrame> _frames = [];

  /// Storm tracks. Its own overlay, drawn over whatever product is up, so it
  /// works the same on velocity or CC as on reflectivity. The cells are
  /// always found in reflectivity — that is where storms are visible — which
  /// is why this keeps its own pair of frames rather than using [frames].
  bool _tracks = false;
  List<StormTrack> _stormTracks = [];
  List<MesoHit> _mesos = [];
  bool _tracksBusy = false;

  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  /// The newest object key the frames on screen were built from, and the one
  /// the in-flight load is building from. Kept so a refresh can tell "no new
  /// scan yet" from "time to reload" by listing alone, without pulling a
  /// volume down again to find out it is the same one.
  ///
  /// Only promoted once a load succeeds: a load that failed leaves the old
  /// key in place, so the next tick sees a mismatch and retries rather than
  /// deciding it is already current.
  String? _newestKey;
  String? _pendingNewestKey;

  /// Colour key for this pane's product. Cached per product so switching
  /// back is instant, and rebuilt when a palette is imported since that
  /// changes the colours on the map.
  ColorScale? _keyScale;
  String? _keyFor;

  String? _sampleText;
  LatLng? _samplePos;
  Timer? _sampleClear;

  int _viewGeneration = 0;

  // Aiming cursor: live value + range/azimuth/height from the radar
  bool _cursor = false;
  LatLng? _cursorPos;
  LatLng? _cursorSite;
  SampleResult? _cursorSample;
  bool _cursorPinned = false;
  bool _cursorBusy = false;
  DateTime _cursorLast = DateTime.fromMillisecondsSinceEpoch(0);

  /// Handle for this pane's decoded sweep in the engine, or null when no
  /// session is open. Every pane holds its own, so two panes with a cursor up
  /// read their own product rather than whichever opened last.
  int? _cursorSession;

  /// Bumped on each open so a slow one that lands after a newer one has
  /// started can tell it lost, and close what it opened instead of installing
  /// a session for a frame the pane has moved off.
  int _cursorSessionGeneration = 0;

  /// An isolated pane is out of the linked group: it ignores the others'
  /// panning and does not move them, so you can park one pane on a second
  /// storm and keep working the rest around it.
  ///
  /// Called isolated rather than locked because nothing is being held shut —
  /// the pane still pans, zooms and follows commands aimed at it on purpose
  /// (picking a radar, "my location", framing an alert). What changes is
  /// only whether it is part of the group.
  bool _isolated = false;

  // An isolated pane runs its own loop. It keeps its own timer rather than
  // stepping off the workspace's, so a pane sitting still costs nothing and
  // the shared clock does not have to know which panes left the group.
  int _localIndex = 0;
  bool _localPlaying = false;
  int _localFrameCount = 1;
  Timer? _localAnim;

  bool _measuring = false;
  final List<LatLng> _measurePts = [];

  // Future radar (on-device nowcast)
  bool _future = false;
  double _futureMinutes = 30;
  DisplayFrame? _futureFrame;
  bool _futureBusy = false;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// State changed *and* the workspace chrome needs to know.
  void _notifyAll() {
    _notify();
    onChanged?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    _localAnim?.cancel();
    _sampleClear?.cancel();
    _closeCursorSession();
    shared.forgetPane(paneId);
    super.dispose();
  }

  // ----------------------------------------------------- what we are on ----

  NexradSite get site => _site;
  RadarProduct get product => _product;
  int get tilt => _tilt;
  bool get loading => _loading;
  String? get error => _error;
  bool get isolated => _isolated;
  bool get cursorOn => _cursor;
  bool get tracksOn => _tracks;
  bool get futureOn => _future;
  bool get measuringOn => _measuring;

  List<DisplayFrame> get frames => List.unmodifiable(_frames);
  int get frameCountLoaded => _frames.length;

  List<StormTrack> get stormTracks => List.unmodifiable(_stormTracks);
  List<MesoHit> get mesos => List.unmodifiable(_mesos);

  ColorScale? get keyScale => _keyScale;

  String? get sampleText => _sampleText;
  LatLng? get samplePos => _samplePos;

  LatLng? get cursorPos => _cursorPos;
  LatLng? get cursorSite => _cursorSite;
  SampleResult? get cursorSample => _cursorSample;
  bool get cursorPinned => _cursorPinned;

  List<LatLng> get measurePts => List.unmodifiable(_measurePts);

  double get futureMinutes => _futureMinutes;
  DisplayFrame? get futureFrame => _futureFrame;

  /// The frame the pane should draw: the nowcast when future radar is on and
  /// has produced one, otherwise the current animation frame.
  DisplayFrame? get displayFrame => _future && _futureFrame != null
      ? _futureFrame
      : (_frames.isEmpty ? null : _frames[shownFrame]);

  int get shownFrame {
    if (_frames.isEmpty) return 0;
    final i = _isolated ? _localIndex : shared.frameIndex;
    if (i < 0) return 0;
    return i >= _frames.length ? _frames.length - 1 : i;
  }

  /// How many frames this pane's loop runs over.
  int get loopLength => _isolated ? _frames.length : shared.loopLength;

  /// Where in that loop it currently is.
  int get frameIndex => shownFrame;

  bool get playing => _isolated ? _localPlaying : shared.playing;

  /// How many frames to fetch. Isolated panes carry their own, so a pane
  /// parked on a second storm can hold a long loop while the group shows
  /// only the latest scan.
  int get frameCount => _isolated ? _localFrameCount : shared.frameCount;

  /// UTC timestamp of the frame on screen, for the status bar.
  DateTime? get frameTime => displayFrame?.time;

  /// Age of the newest frame we hold, regardless of where the loop is.
  Duration? get dataAge => _frames.isEmpty
      ? null
      : DateTime.now().toUtc().difference(_frames.last.time);

  /// Whether the newest scan is old enough to say so. Never during replay:
  /// data from 1998 is meant to be old.
  bool get isStale {
    if (shared.historyTime != null) return false;
    final age = dataAge;
    return age != null && age > staleAfter;
  }

  double? get elevationDeg {
    final f = displayFrame;
    if (f == null || !_product.hasTilts) return null;
    return f.meta.elevationDeg;
  }

  // ---------------------------------------------------------- animation ----

  void togglePlay() {
    _localPlaying = !_localPlaying;
    _syncLocalAnim();
    _notifyAll();
  }

  void step(int delta) {
    final n = _frames.length;
    if (n == 0) return;
    _localPlaying = false;
    _localIndex = (_localIndex.clamp(0, n - 1) + delta) % n;
    if (_localIndex < 0) _localIndex += n;
    _syncLocalAnim();
    _notifyAll();
  }

  void setFrameCount(int n) {
    if (_localFrameCount == n) return;
    _localFrameCount = n;
    _localPlaying = n > 1;
    _syncLocalAnim();
    _notifyAll();
    unawaited(loadFrames());
  }

  /// Starts or stops this pane's own ticker. Only runs while the pane is
  /// both isolated and playing.
  void _syncLocalAnim() {
    final wanted = _isolated && _localPlaying;
    if (wanted && _localAnim == null) {
      _localAnim = Timer.periodic(const Duration(milliseconds: 350), (_) {
        final n = _frames.length;
        if (n < 2 || _disposed) return;
        // Dwell on the newest frame for a few ticks before looping, the
        // same as the shared clock.
        _localIndex = _localIndex >= n - 1 + 3 ? 0 : _localIndex + 1;
        _notify();
      });
    } else if (!wanted) {
      _localAnim?.cancel();
      _localAnim = null;
    }
  }

  // ----------------------------------------------------------- commands ----

  void setProduct(RadarProduct p) {
    if (identical(p, _product)) return;
    _product = p;
    _futureFrame = null;
    _notifyAll();
    unawaited(loadFrames());
  }

  void setTilt(int t) {
    if (t == _tilt) return;
    _tilt = t;
    _futureFrame = null;
    _notifyAll();
    unawaited(loadFrames());
  }

  void selectSite(NexradSite s, {bool moveMap = false}) {
    if (s.icao == _site.icao) return;
    _site = s;
    _futureFrame = null;
    // Locked panes move too. Picking a radar is an explicit command, the
    // same class as "my location" and zoom-to-alert, which already override
    // the lock. Holding a locked pane's framing across a site change left it
    // pointed at ground the new radar cannot see, so it went blank — which
    // reads as the pane having failed to switch at all.
    if (moveMap) {
      final zoom = viewport?.call()?.zoom;
      if (zoom != null) onMoveMap?.call(LatLng(s.lat, s.lon), zoom);
    }
    _notifyAll();
    unawaited(loadFrames());
  }

  void toggleCursor() {
    _cursor = !_cursor;
    if (!_cursor) {
      _cursorPos = null;
      _cursorSample = null;
      _cursorPinned = false;
      _closeCursorSession();
    }
    _notifyAll();
    if (_cursor) unawaited(openCursorSession());
  }

  void toggleTracks() {
    _tracks = !_tracks;
    if (!_tracks) {
      _stormTracks = [];
      _mesos = [];
    }
    _notifyAll();
    if (_tracks) unawaited(updateTracks());
  }

  /// Adopt another pane's site and tilt in one step.
  ///
  /// Separate from [selectSite] and [setTilt] so rejoining a group costs one
  /// reload rather than two, and so a pane that is already in step does
  /// nothing at all.
  void syncTo({NexradSite? site, int? tilt}) {
    final newSite = (site != null && site.icao != _site.icao) ? site : null;
    final newTilt = (tilt != null && tilt != _tilt) ? tilt : null;
    if (newSite == null && newTilt == null) return;
    if (newSite != null) _site = newSite;
    if (newTilt != null) _tilt = newTilt;
    _futureFrame = null;
    _notifyAll();
    unawaited(loadFrames());
  }

  void toggleIsolate() {
    // Carry the frame across so the picture does not jump at the moment the
    // pane changes hands between the two clocks.
    final carried = shownFrame;
    _isolated = !_isolated;
    if (_isolated) {
      _localIndex = carried;
      _localFrameCount = shared.frameCount;
      _localPlaying = shared.playing;
    } else {
      _localPlaying = false;
    }
    if (_isolated) {
      // Out of the group: stop stretching the shared loop's length.
      shared.forgetPane(paneId);
    } else {
      shared.reportFrames(paneId, _frames.length);
    }
    _syncLocalAnim();
    _notifyAll();
  }

  void toggleMeasure() {
    _measuring = !_measuring;
    _measurePts.clear();
    _notifyAll();
  }

  void addMeasurePoint(LatLng p) {
    if (_measurePts.length >= 2) _measurePts.clear();
    _measurePts.add(p);
    _notify();
  }

  void toggleFuture() {
    _future = !_future;
    if (!_future) _futureFrame = null;
    _notifyAll();
    if (_future) unawaited(renderFuture());
  }

  void setFutureMinutes(double minutes) {
    if (_futureMinutes == minutes) return;
    _futureMinutes = minutes;
    _notify();
  }

  void commitFutureMinutes() => unawaited(renderFuture());

  // --------------------------------------------------------------- data ----

  Future<void> loadFrames() async {
    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    _notifyAll();
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
      _newestKey = _pendingNewestKey;
      _loading = false;
      if (!_isolated) shared.reportFrames(paneId, frames.length);
      _notifyAll();
      // Sharpen for the current viewport right away.
      unawaited(renderViewport());
      unawaited(updateTracks());
      unawaited(_loadColorKey(frames.isEmpty ? null : frames.last));
      if (_cursor) unawaited(openCursorSession());
    } catch (e) {
      if (generation != _loadGeneration || _disposed) return;
      _loading = false;
      _error = e.toString();
      if (!_isolated) shared.reportFrames(paneId, 0);
      _notifyAll();
    }
  }

  /// Reload, but only if the radar has actually produced a new scan.
  ///
  /// Called on the workspace's refresh clock. Until this existed nothing ever
  /// refetched: frames arrived on the first load and then sat there until the
  /// user changed a product or pressed reload, so a pane left open showed
  /// weather as old as the moment it was opened (#45).
  ///
  /// The check is a listing, not a download. If the newest key matches what
  /// is already on screen there is no new scan and nothing else happens, so
  /// the common case costs one small request per pane per minute.
  Future<void> refreshForNewData() async {
    if (_disposed || _loading) return;
    // Replay pins the pane to a chosen moment; refreshing would haul it back
    // to now, which is the opposite of what the user asked for.
    if (shared.historyTime != null) return;
    // Nothing loaded and nothing failed means this pane has not had its first
    // load yet — it is waiting on the site to settle, and jumping in here
    // would fetch the fallback site's data just to throw it away.
    if (_frames.isEmpty && _error == null) return;
    try {
      final latest = await _latestKey();
      if (_disposed || _loading || latest == null) return;
      if (latest == _newestKey) return;
      await loadFrames();
    } catch (_) {
      // A listing that failed is not worth surfacing over frames that are
      // still on screen and still readable. The next tick tries again.
    }
  }

  /// The newest key available for what this pane is showing, by listing only.
  Future<String?> _latestKey() async {
    if (_product.isMrms) {
      final keys = await listRecentMosaics(count: 1);
      return keys.isEmpty ? null : keys.last;
    }
    if (_product.isLevel2) {
      final keys = await volumeKeys(1);
      return keys.isEmpty ? null : keys.last;
    }
    final keys = await listRecentKeys(
      _site.shortId,
      _product.code(_tilt),
      count: 1,
    );
    return keys.isEmpty ? null : keys.last;
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

  Future<List<DisplayFrame>> _loadLevel3Frames() async {
    final productCode = _product.code(_tilt);
    final keys = await listRecentKeys(
      _site.shortId,
      productCode,
      count: frameCount,
      before: shared.historyTime,
    );
    if (keys.isEmpty) {
      throw Exception('no recent $productCode data for ${_site.icao}');
    }
    _pendingNewestKey = keys.last;
    return Future.wait(keys.map((key) async {
      final bytes = Uint8List.fromList(await fetchObject(key));
      final frame = await renderLevel3Frame(data: bytes, imageSize: 1024);
      return DisplayFrame(frame, MemoryImage(frame.png), bytes);
    }));
  }

  /// The national mosaic is one CONUS grid per file; decode covers the whole
  /// country, so the initial render just uses the grid's own bounds.
  Future<List<DisplayFrame>> _loadMrmsFrames() async {
    final keys = await listRecentMosaics(
      count: math.min(frameCount, 6),
      before: shared.historyTime,
    );
    if (keys.isEmpty) throw Exception('no recent MRMS mosaics');
    _pendingNewestKey = keys.last;
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
      frames.add(DisplayFrame(frame, MemoryImage(frame.png), bytes));
    }
    return frames;
  }

  /// The recent-volume listing for this pane's site, shared so four panes
  /// asking at the same moment issue one request.
  Future<List<String>> volumeKeys(int count) {
    final before = shared.historyTime;
    return shared.listing(
      'vol|${_site.icao}|$count|${before?.toIso8601String() ?? ''}',
      () => listRecentVolumes(_site.icao, count: count, before: before),
    );
  }

  /// Level 2 volumes are big (5-15 MB), so cap the loop length and share the
  /// raw bytes so tilt/moment switches don't re-download.
  Future<List<DisplayFrame>> _loadLevel2Frames() async {
    final count = math.min(frameCount, 4);
    final keys = await volumeKeys(count);
    if (keys.isEmpty) {
      throw Exception('no recent Level 2 volumes for ${_site.icao}');
    }
    _pendingNewestKey = keys.last;
    final frames = <DisplayFrame>[];
    for (final key in keys) {
      // Shared across panes: the L2 products a 2x2 compares all read the
      // same volume, so this is one download for all of them.
      final bytes = await shared.volume(key, () => fetchVolume(key));
      final frame = await renderLevel2Frame(
        data: bytes,
        moment: _product.l2Moment!,
        elevationIndex: _product.hasTilts ? _tilt : 0,
        imageSize: 1024,
      );
      frames.add(DisplayFrame(frame, MemoryImage(frame.png), bytes));
    }
    return frames;
  }

  /// Fetch NOAA's storm tracks for this site.
  ///
  /// These come from the NWS's own SCIT, published as Level 3 STI, rather
  /// than being worked out here: it runs across seven reflectivity
  /// thresholds with full vertical integration and gives a forecast error
  /// estimate, none of which is reachable from one 2D field on device.
  ///
  /// Independent of the displayed product, so the overlay works the same
  /// over velocity or CC as over reflectivity.
  Future<void> updateTracks() async {
    if (!_tracks || _tracksBusy) return;
    _tracksBusy = true;
    try {
      final keys = await listRecentKeys(
        _site.shortId,
        'NST',
        count: 1,
        before: shared.historyTime,
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
          before: shared.historyTime,
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

  /// Fetch the colour scale for whatever is on screen. Keyed by product plus
  /// palette generation so an imported `.pal` refreshes the key too.
  Future<void> _loadColorKey(DisplayFrame? frame) async {
    final id = '${_product.short}|${shared.paletteGeneration}';
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

  // ------------------------------------------------------------- cursor ----

  /// Point the cursor at the frame currently on screen. Cheap to call: the
  /// engine keeps the decoded sweep so each aim is just a lookup.
  Future<void> openCursorSession() async {
    if (!_cursor || _frames.isEmpty || _product.isMrms) return;
    final frame = _frames[shownFrame];
    final generation = ++_cursorSessionGeneration;
    try {
      final session = _product.isLevel2
          ? await inspectOpenLevel2(
              data: frame.raw,
              moment: _product.l2Moment!,
              elevationIndex: _product.hasTilts ? _tilt : 0,
            )
          : await inspectOpenLevel3(data: frame.raw);
      // Another open (or a dispose) overtook this one while it decoded: the
      // sweep just built is for a frame nobody is looking at any more.
      if (_disposed || generation != _cursorSessionGeneration) {
        unawaited(inspectClose(session: session));
        return;
      }
      final previous = _cursorSession;
      _cursorSession = session;
      if (previous != null) unawaited(inspectClose(session: previous));

      final site = await inspectSite(session: session);
      if (_disposed || _cursorSession != session) return;
      _cursorSite = site.length >= 2 ? LatLng(site[0], site[1]) : null;
      _notify();
      // Keep a pinned readout current as frames advance.
      final at = _cursorPos;
      if (at != null) {
        final s = await inspectSample(
          session: session,
          lat: at.latitude,
          lon: at.longitude,
        );
        if (_disposed || _cursorSession != session) return;
        _cursorSample = s;
        _notify();
      }
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _notify();
    }
  }

  /// Hand this pane's sweep back to the engine. Safe to call when nothing is
  /// open, and safe to call twice.
  void _closeCursorSession() {
    final session = _cursorSession;
    _cursorSession = null;
    // Retire any open still in flight along with it, so it closes itself
    // rather than installing a session on a pane that has finished with one.
    _cursorSessionGeneration++;
    if (session != null) unawaited(inspectClose(session: session));
  }

  /// Aim at a point and read the value there. Throttled so a moving pointer
  /// doesn't queue up work.
  ///
  /// [fromTap] pins the cursor so it stays put; while pinned, hovering does
  /// not move it. Releasing a pin is [unpinCursor], which the widget calls
  /// when the tap landed on the pin itself — that hit test needs the map
  /// camera, so it belongs to the layer that has one.
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
    final session = _cursorSession;
    if (session == null) return; // open still in flight; it will sample once done
    _cursorBusy = true;
    _cursorLast = now;
    try {
      final s = await inspectSample(
        session: session,
        lat: p.latitude,
        lon: p.longitude,
      );
      // A reload may have swapped the session out from under this sample, in
      // which case the value is from a frame that is no longer on screen.
      if (_disposed || _cursorSession != session) return;
      _cursorSample = s;
      _notify();
    } catch (_) {
      // Session closed mid-sample (product switch); the next aim will retry.
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

  // -------------------------------------------------------------- tools ----

  /// Write the current radar image to the user's pictures folder. Named
  /// apart from the `saveSnapshot` it calls: a method of the same name would
  /// win over the library function inside this class and recurse.
  String? saveFrameSnapshot() {
    final frame = displayFrame;
    if (frame == null) return null;
    try {
      final f = saveSnapshot(
        frame.meta.png,
        '${_product.isMrms ? 'MRMS' : _site.icao}_${_product.short}'
            .replaceAll(' ', ''),
      );
      return f.path;
    } catch (e) {
      if (_disposed) return null;
      _error = e.toString();
      _notify();
      return null;
    }
  }

  /// Fetch the Level 2 volume the 3D view should open on, at the moment
  /// currently being shown. The widget does the navigating.
  ///
  /// Replay time matters: without it the map showed the chosen time while 3D
  /// silently jumped to now, which is worse than not replaying at all
  /// because nothing on screen says the two disagree.
  Future<Uint8List?> prepareVolume() async {
    _loading = true;
    _notifyAll();
    try {
      final keys = await volumeKeys(1);
      if (keys.isEmpty) throw Exception('no volume for ${_site.icao}');
      final bytes = await shared.volume(keys.last, () => fetchVolume(keys.last));
      if (_disposed) return null;
      _loading = false;
      _notifyAll();
      return bytes;
    } catch (e) {
      if (_disposed) return null;
      _loading = false;
      _error = e.toString();
      _notifyAll();
      return null;
    }
  }

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
      final beamKft = s.beamHeightM * 3.28084 / 1000.0;
      final valueText = s.rangeFolded
          ? 'RF'
          : s.value == null
              ? 'no data'
              : '${s.value!.toStringAsFixed(1)} ${s.unit}'.trim();
      if (_disposed) return;
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

  // ------------------------------------------------------------- render ----

  /// Visible box expanded slightly, clipped to the data extent, plus the
  /// pixel size to render it at.
  ViewBox? _viewBox() {
    final vp = viewport?.call();
    if (vp == null || _frames.isEmpty || _disposed) return null;
    if (vp.pixelWidth <= 0) return null;
    final dLat = (vp.north - vp.south) * 0.25;
    final dLon = (vp.east - vp.west) * 0.25;
    var north = vp.north + dLat;
    var south = vp.south - dLat;
    var east = vp.east + dLon;
    var west = vp.west - dLon;
    final d = _frames.first.dataBounds;
    north = math.min(north, d.north);
    south = math.max(south, d.south);
    east = math.min(east, d.east);
    west = math.max(west, d.west);
    if (north <= south || east <= west) return null;

    // Pixel size: match this pane's on-screen density, capped to keep
    // renders fast. Four panes at a quarter of the area each therefore ask
    // for a quarter of the pixels, rather than four full-window renders.
    final pxPerLon = vp.pixelWidth / (vp.east - vp.west);
    final width = ((east - west) * pxPerLon).round().clamp(256, 2200);
    double mercY(double latDeg) {
      final lat = latDeg * math.pi / 180.0;
      return math.log(math.tan(math.pi / 4 + lat / 2));
    }

    final aspect =
        (mercY(north) - mercY(south)) / ((east - west) * math.pi / 180.0);
    final height = (width * aspect).round().clamp(256, 2200);
    return (n: north, s: south, e: east, w: west, width: width, height: height);
  }

  /// Extrapolate the two most recent frames forward on-device.
  Future<void> renderFuture() async {
    if (!_future || _futureBusy) return;
    if (_product.isLevel2) {
      _error = 'Future radar needs a Level 3 or mosaic product';
      _notifyAll();
      return;
    }
    if (_frames.length < 2) {
      // Need a previous scan to measure motion against.
      if (frameCount < 4) {
        if (_isolated) {
          setFrameCount(4);
        } else {
          shared.setFrameCount(4);
        }
        await loadFrames();
      }
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
      final img = MemoryImage(r.png);
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

  /// Zoomed out past a single radar's useful range, hand over to the
  /// national mosaic; zoom back in and the site radar returns.
  ///
  /// [multiPane] switches this off. In a multi-panel comparison it would be
  /// actively hostile: zooming out to see the whole line would silently
  /// replace the velocity and dual-pol panes with four copies of the same
  /// mosaic, throwing away the arrangement the user built.
  void maybeSwitchMosaic({required bool multiPane}) {
    if (_loading || multiPane) return;
    final zoom = viewport?.call()?.zoom;
    if (zoom == null) return;
    if (zoom < 6.0 && identical(_product, productRef)) {
      setProduct(mrmsProduct);
    } else if (zoom >= 6.5 && _product.isMrms) {
      setProduct(productRef);
    }
  }

  /// Re-render the loaded frames for the current viewport, so 250 m gates
  /// stay sharp when zoomed in.
  ///
  /// The frame on screen goes first and is swapped in on its own, because
  /// that is the one being waited on. The rest of the loop follows. Doing
  /// the whole loop before showing anything meant a twelve-frame animation
  /// took twelve renders to sharpen — and for Level 2, twelve re-decodes of
  /// a 5-15 MB volume.
  Future<void> renderViewport() async {
    if (_frames.isEmpty || _disposed) return;
    final box = _viewBox();
    if (box == null) return;
    final generation = ++_viewGeneration;
    final bounds = LatLngBounds(LatLng(box.n, box.w), LatLng(box.s, box.e));

    Future<MemoryImage?> renderOne(DisplayFrame f) async {
      try {
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
        return MemoryImage(r.png);
      } catch (_) {
        // One bad frame must not cost the rest of the loop its sharpening.
        return null;
      }
    }

    final shown = shownFrame;
    final first = await renderOne(_frames[shown]);
    if (generation != _viewGeneration || _disposed) return;
    if (first != null) {
      await _warmImage(first);
      if (generation != _viewGeneration || _disposed) return;
      _frames[shown].image = first;
      _frames[shown].bounds = bounds;
      _notify();
    }

    final rest = [
      for (var i = 0; i < _frames.length; i++)
        if (i != shown) i,
    ];
    if (rest.isNotEmpty) {
      final images = await Future.wait(rest.map((i) => renderOne(_frames[i])));
      if (generation != _viewGeneration || _disposed) return;
      await Future.wait([
        for (final img in images)
          if (img != null) _warmImage(img),
      ]);
      if (generation != _viewGeneration || _disposed) return;
      for (var k = 0; k < rest.length; k++) {
        final img = images[k];
        if (img == null) continue;
        _frames[rest[k]].image = img;
        _frames[rest[k]].bounds = bounds;
      }
      _notify();
    }

    if (_future) unawaited(renderFuture());
  }
}
