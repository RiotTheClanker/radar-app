/// One radar view: a map, a product, and the overlays that go on it.
///
/// This is everything that used to be `_RadarScreenState` minus the chrome.
/// The split is what makes multiple panes possible at all: a pane owns its
/// site, product, tilt and decoded frames, while the things that are true of
/// the whole workspace — alerts, lightning, the animation clock, the replay
/// time — live in [WorkspaceState] and are read from there.
///
/// The workspace drives a pane through its [RadarPaneState], reached with a
/// [GlobalKey]. That is a blunter instrument than a callback interface, but
/// the toolbar genuinely does need to reach into whichever pane has focus and
/// change its product, and routing every one of those through the parent's
/// [State] would be the same coupling with more indirection.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import '../data/hydrometeor.dart';
import '../data/identity.dart';
import '../data/level2_fetcher.dart';
import '../data/level3_fetcher.dart';
import '../data/lightning.dart';
import '../data/mrms_fetcher.dart';
import '../data/nexrad_sites.g.dart';
import '../data/user_files.dart';
import '../src/rust/api/radar.dart';
import 'alert_sheets.dart';
import 'color_key.dart';
import 'hydro_legend.dart';
import 'pane_models.dart';
import 'volume3d_screen.dart';
import 'workspace_state.dart';
import 'wx_theme.dart';

class _Frame {
  final RadarFrame meta;

  /// Source bytes the frame was decoded from, kept for the inspector and
  /// viewport re-renders.
  final Uint8List raw;

  /// Currently displayed overlay (swapped on viewport re-render).
  MemoryImage image;
  LatLngBounds bounds;

  _Frame(this.meta, this.image, this.raw)
      : bounds = LatLngBounds(
          LatLng(meta.north, meta.west),
          LatLng(meta.south, meta.east),
        );

  /// Full extent of the radar data disk (from the initial whole-disk render).
  LatLngBounds get dataBounds => LatLngBounds(
        LatLng(meta.north, meta.west),
        LatLng(meta.south, meta.east),
      );
}

class RadarPane extends StatefulWidget {
  const RadarPane({
    super.key,
    required this.paneId,
    required this.shared,
    required this.initialSite,
    required this.initialProduct,
    required this.focused,
    required this.onFocus,
    required this.onChanged,
    required this.onCameraMoved,
    required this.showHeader,
    required this.autoLoad,
    this.initialCenter,
    this.initialZoom,
  });

  /// Stable index within the workspace, used to key this pane's contribution
  /// to the shared animation clock.
  final int paneId;
  final WorkspaceState shared;
  final NexradSite initialSite;
  final RadarProduct initialProduct;

  /// Whether the toolbar's actions currently land here.
  final bool focused;
  final VoidCallback onFocus;

  /// Something the toolbar displays changed — product, tilt, site, frame
  /// time, load state.
  final VoidCallback onChanged;

  /// A user gesture moved this pane's map. The workspace decides whether to
  /// pass that on to the others.
  final void Function(int paneId, LatLng center, double zoom) onCameraMoved;

  /// Panes label themselves once there is more than one of them; with a
  /// single pane the toolbar already says all of this.
  final bool showHeader;

  /// Whether this pane may fetch yet. Held false until the workspace has
  /// finished working out where we are, so a cold start does not fetch the
  /// fallback site's data and then immediately throw it away — which for a
  /// Level 2 product is a wasted 10 MB per pane.
  final bool autoLoad;

  /// Where a newly built pane opens. Panes added by growing the layout are
  /// born looking at what the others are looking at, rather than jumping
  /// there a frame later.
  final LatLng? initialCenter;
  final double? initialZoom;

  @override
  State<RadarPane> createState() => RadarPaneState();
}

class RadarPaneState extends State<RadarPane> {
  final _mapController = MapController();
  bool _mapReady = false;

  late NexradSite _site = widget.initialSite;
  late RadarProduct _product = widget.initialProduct;
  int _tilt = 0;

  List<_Frame> _frames = [];

  /// Storm tracks. Its own overlay, drawn over whatever product is up, so it
  /// works the same on velocity or CC as on reflectivity. The cells are
  /// always found in reflectivity — that is where storms are visible — which
  /// is why this keeps its own pair of frames rather than using [_frames].
  bool _tracks = false;
  List<StormTrack> _stormTracks = [];
  List<MesoHit> _mesos = [];
  bool _tracksBusy = false;

  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  /// Colour key for this pane's product. Cached per product so switching back
  /// is instant, and rebuilt when a palette is imported since that changes
  /// the colours on the map.
  ColorScale? _keyScale;
  String? _keyFor;

  final LayerHitNotifier<WeatherAlert> _alertHit = ValueNotifier(null);
  final Map<String, Uint8List> _l2Cache = {};

  String? _sampleText;
  LatLng? _samplePos;
  Timer? _sampleClear;

  Timer? _viewDebounce;
  int _viewGeneration = 0;

  /// The pane's own size, in logical pixels. Viewport re-rendering used to
  /// read this off [MediaQuery], which was the same thing while the map was
  /// the whole window. In a 2x2 it is four times too many pixels.
  Size _paneSize = Size.zero;

  // Aiming cursor: live value + range/azimuth/height from the radar
  bool _cursor = false;
  LatLng? _cursorPos;
  LatLng? _cursorSite;
  SampleResult? _cursorSample;
  bool _cursorPinned = false;
  bool _cursorBusy = false;
  DateTime _cursorLast = DateTime.fromMillisecondsSinceEpoch(0);

  bool _measuring = false;
  final List<LatLng> _measurePts = [];

  // Future radar (on-device nowcast)
  bool _future = false;
  double _futureMinutes = 30;
  _Frame? _futureFrame;
  bool _futureBusy = false;

  @override
  void initState() {
    super.initState();
    widget.shared.addListener(_onShared);
    // Deferred: [loadFrames] calls setState before its first await, and doing
    // that while the State is still being constructed is an error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.autoLoad) unawaited(loadFrames());
    });
  }

  @override
  void didUpdateWidget(RadarPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The workspace has settled on a site; this is the first honest load.
    if (widget.autoLoad &&
        !oldWidget.autoLoad &&
        _frames.isEmpty &&
        !_loading) {
      unawaited(loadFrames());
    }
  }

  @override
  void dispose() {
    widget.shared.removeListener(_onShared);
    widget.shared.forgetPane(widget.paneId);
    _sampleClear?.cancel();
    _viewDebounce?.cancel();
    _alertHit.dispose();
    _mapController.dispose();
    super.dispose();
  }

  /// Shared state moved. Alerts, lightning, the clock and the basemap all
  /// just repaint; anything needing a refetch is reloaded by the workspace,
  /// which is the only side that knows a reload is warranted.
  void _onShared() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------ what we are on ----

  NexradSite get site => _site;
  RadarProduct get product => _product;
  int get tilt => _tilt;
  bool get loading => _loading;
  String? get error => _error;
  bool get cursorOn => _cursor;
  bool get tracksOn => _tracks;
  bool get futureOn => _future;
  bool get measuringOn => _measuring;
  int get frameCountLoaded => _frames.length;
  MapController get mapController => _mapController;

  /// Where this pane is looking, or null before the map is attached.
  ({LatLng center, double zoom})? get cameraOrNull {
    if (!_mapReady) return null;
    final c = _mapController.camera;
    return (center: c.center, zoom: c.zoom);
  }

  _Frame? get _displayFrame => _future && _futureFrame != null
      ? _futureFrame
      : (_frames.isEmpty ? null : _frames[_shownFrame]);

  int get _shownFrame {
    if (_frames.isEmpty) return 0;
    final i = widget.shared.frameIndex;
    if (i < 0) return 0;
    return i >= _frames.length ? _frames.length - 1 : i;
  }

  /// UTC timestamp of the frame on screen, for the status bar.
  DateTime? get frameTime {
    final f = _displayFrame;
    if (f == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      f.meta.timestamp.toInt() * 1000,
      isUtc: true,
    );
  }

  /// Age of the newest frame we hold, regardless of where the loop is.
  Duration? get dataAge {
    if (_frames.isEmpty) return null;
    return DateTime.now().toUtc().difference(
          DateTime.fromMillisecondsSinceEpoch(
            _frames.last.meta.timestamp.toInt() * 1000,
            isUtc: true,
          ),
        );
  }

  double? get elevationDeg {
    final f = _displayFrame;
    if (f == null || !_product.hasTilts) return null;
    return f.meta.elevationDeg;
  }

  // ----------------------------------------------------------- commands ----

  void setProduct(RadarProduct p) {
    if (identical(p, _product)) return;
    setState(() {
      _product = p;
      _frames = [];
      _futureFrame = null;
    });
    widget.onChanged();
    unawaited(loadFrames());
  }

  void setTilt(int t) {
    if (t == _tilt) return;
    setState(() {
      _tilt = t;
      _frames = [];
      _futureFrame = null;
    });
    widget.onChanged();
    unawaited(loadFrames());
  }

  void selectSite(NexradSite s, {bool moveMap = false}) {
    if (s.icao == _site.icao) return;
    setState(() {
      _site = s;
      _frames = [];
      _futureFrame = null;
    });
    if (moveMap && _mapReady) {
      _mapController.move(LatLng(s.lat, s.lon), _mapController.camera.zoom);
    }
    widget.onChanged();
    unawaited(loadFrames());
  }

  void toggleCursor() {
    setState(() {
      _cursor = !_cursor;
      if (!_cursor) {
        _cursorPos = null;
        _cursorSample = null;
        _cursorPinned = false;
      }
    });
    widget.onChanged();
    if (_cursor) unawaited(_openCursorSession());
  }

  void toggleTracks() {
    setState(() {
      _tracks = !_tracks;
      if (!_tracks) {
        _stormTracks = [];
        _mesos = [];
      }
    });
    widget.onChanged();
    if (_tracks) unawaited(_updateTracks());
  }

  void toggleMeasure() {
    setState(() {
      _measuring = !_measuring;
      _measurePts.clear();
    });
    widget.onChanged();
  }

  void toggleFuture() {
    setState(() {
      _future = !_future;
      if (!_future) _futureFrame = null;
    });
    widget.onChanged();
    if (_future) unawaited(_renderFuture());
  }

  /// Move this pane's camera without echoing the move back to the workspace.
  /// Used for view linking; guarded so a pane that is already there does not
  /// start a ping-pong of moves between panes.
  void applyCamera(LatLng center, double zoom) {
    if (!mounted || !_mapReady) return;
    final cam = _mapController.camera;
    const eps = 1e-7;
    if ((cam.center.latitude - center.latitude).abs() < eps &&
        (cam.center.longitude - center.longitude).abs() < eps &&
        (cam.zoom - zoom).abs() < eps) {
      return;
    }
    _mapController.move(center, zoom);
  }

  void frameBounds(LatLngBounds bounds) {
    if (!_mapReady) return;
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
    );
  }

  // --------------------------------------------------------------- data ----

  Future<void> loadFrames() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    widget.onChanged();
    try {
      final frames = _product.isMrms
          ? await _loadMrmsFrames()
          : _product.isLevel2
              ? await _loadLevel2Frames()
              : await _loadLevel3Frames();
      if (generation != _loadGeneration || !mounted) return;
      for (final f in frames) {
        // Warm the image cache so animation doesn't flicker.
        // ignore: use_build_context_synchronously
        await precacheImage(f.image, context);
      }
      if (generation != _loadGeneration || !mounted) return;
      setState(() {
        _frames = frames;
        _loading = false;
      });
      widget.shared.reportFrames(widget.paneId, frames.length);
      widget.onChanged();
      // Sharpen for the current viewport right away.
      unawaited(_renderViewport());
      unawaited(_updateTracks());
      unawaited(_loadColorKey(frames.isEmpty ? null : frames.last));
      if (_cursor) unawaited(_openCursorSession());
    } catch (e) {
      if (generation != _loadGeneration || !mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      widget.shared.reportFrames(widget.paneId, 0);
      widget.onChanged();
    }
  }

  Future<List<_Frame>> _loadLevel3Frames() async {
    final productCode = _product.code(_tilt);
    final keys = await listRecentKeys(
      _site.shortId,
      productCode,
      count: widget.shared.frameCount,
      before: widget.shared.historyTime,
    );
    if (keys.isEmpty) {
      throw Exception('no recent $productCode data for ${_site.icao}');
    }
    return Future.wait(keys.map((key) async {
      final bytes = Uint8List.fromList(await fetchObject(key));
      final frame = await renderLevel3Frame(data: bytes, imageSize: 1024);
      return _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes);
    }));
  }

  /// The national mosaic is one CONUS grid per file; decode covers the whole
  /// country, so the initial render just uses the grid's own bounds.
  Future<List<_Frame>> _loadMrmsFrames() async {
    final keys = await listRecentMosaics(
      count: math.min(widget.shared.frameCount, 6),
      before: widget.shared.historyTime,
    );
    if (keys.isEmpty) throw Exception('no recent MRMS mosaics');
    final frames = <_Frame>[];
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
      frames.add(
        _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes),
      );
    }
    return frames;
  }

  /// Level 2 volumes are big (5-15 MB), so cap the loop length and cache the
  /// raw bytes so tilt/moment switches don't re-download.
  Future<List<_Frame>> _loadLevel2Frames() async {
    final count = math.min(widget.shared.frameCount, 4);
    final keys = await listRecentVolumes(
      _site.icao,
      count: count,
      before: widget.shared.historyTime,
    );
    if (keys.isEmpty) {
      throw Exception('no recent Level 2 volumes for ${_site.icao}');
    }
    final frames = <_Frame>[];
    for (final key in keys) {
      final bytes = _l2Cache[key] ?? await fetchVolume(key);
      _l2Cache[key] = bytes;
      final frame = await renderLevel2Frame(
        data: bytes,
        moment: _product.l2Moment!,
        elevationIndex: _product.hasTilts ? _tilt : 0,
        imageSize: 1024,
      );
      frames.add(
        _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes),
      );
    }
    while (_l2Cache.length > 6) {
      _l2Cache.remove(_l2Cache.keys.first);
    }
    return frames;
  }

  /// Fetch NOAA's storm tracks for this site.
  ///
  /// These come from the NWS's own SCIT, published as Level 3 STI, rather
  /// than being worked out here: it runs across seven reflectivity thresholds
  /// with full vertical integration and gives a forecast error estimate, none
  /// of which is reachable from one 2D field on device.
  ///
  /// Independent of the displayed product, so the overlay works the same over
  /// velocity or CC as over reflectivity.
  Future<void> _updateTracks() async {
    if (!_tracks || _tracksBusy) return;
    _tracksBusy = true;
    try {
      final keys = await listRecentKeys(
        _site.shortId,
        'NST',
        count: 1,
        before: widget.shared.historyTime,
      );
      if (keys.isEmpty) {
        if (mounted && _tracks) setState(() => _stormTracks = []);
        return;
      }
      final bytes = Uint8List.fromList(await fetchObject(keys.last));
      final tracks = await stormTracks(data: bytes);

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
          before: widget.shared.historyTime,
        );
        if (mdKeys.isNotEmpty) {
          circs = await mesocyclones(
            data: Uint8List.fromList(await fetchObject(mdKeys.last)),
          );
        }
      } catch (_) {
        // Tracks are still worth showing without rotation data.
      }

      if (!mounted || !_tracks) return;
      setState(() {
        _stormTracks = tracks;
        _mesos = circs;
      });
    } catch (_) {
      // Tracks are an extra: a failure here must not disturb the radar. A
      // site with no storms publishes no cells, which is not an error.
      if (mounted && _tracks) {
        setState(() {
          _stormTracks = [];
          _mesos = [];
        });
      }
    } finally {
      _tracksBusy = false;
    }
  }

  /// Fetch the colour scale for whatever is on screen. Keyed by product plus
  /// palette generation so an imported `.pal` refreshes the key too.
  Future<void> _loadColorKey(_Frame? frame) async {
    final id = '${_product.short}|${widget.shared.paletteGeneration}';
    if (_keyFor == id) return;
    try {
      final scale = await colorScale(
        productCode: _product.isLevel2 || _product.isMrms
            ? 0
            : (frame?.meta.productCode ?? 0),
        moment: _product.l2Moment ?? '',
      );
      if (!mounted) return;
      setState(() {
        _keyScale = scale;
        _keyFor = id;
      });
    } catch (_) {
      // The map is still readable without a key.
    }
  }

  // ------------------------------------------------------------- cursor ----

  /// Point the cursor at the frame currently on screen. Cheap to call: the
  /// engine keeps the decoded sweep so each aim is just a lookup.
  Future<void> _openCursorSession() async {
    if (!_cursor || _frames.isEmpty || _product.isMrms) return;
    final frame = _frames[_shownFrame];
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
      if (!mounted) return;
      setState(() {
        _cursorSite = site.length >= 2 ? LatLng(site[0], site[1]) : null;
      });
      // Keep a pinned readout current as frames advance.
      final at = _cursorPos;
      if (at != null) {
        final s = await inspectSample(lat: at.latitude, lon: at.longitude);
        if (mounted) setState(() => _cursorSample = s);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Aim at a point and read the value there. Throttled so a moving pointer
  /// doesn't queue up work. A tap pins the cursor so it stays put (tapping
  /// it again releases it); while pinned, hovering does not move it.
  Future<void> _aimCursor(LatLng p, {bool fromTap = false}) async {
    if (!_cursor) return;
    if (fromTap) {
      final existing = _cursorPos;
      if (_cursorPinned && existing != null && _mapReady) {
        final cam = _mapController.camera;
        final d =
            (cam.latLngToScreenOffset(existing) - cam.latLngToScreenOffset(p))
                .distance;
        if (d < 24) {
          // Tapped the pin itself: release it.
          setState(() => _cursorPinned = false);
          return;
        }
      }
      setState(() => _cursorPinned = true);
    } else if (_cursorPinned) {
      return; // pinned: ignore pointer movement
    }
    setState(() => _cursorPos = p);
    final now = DateTime.now();
    if (!fromTap &&
        (_cursorBusy || now.difference(_cursorLast).inMilliseconds < 60)) {
      return;
    }
    _cursorBusy = true;
    _cursorLast = now;
    try {
      final s = await inspectSample(lat: p.latitude, lon: p.longitude);
      if (mounted) setState(() => _cursorSample = s);
    } catch (_) {
      // No session yet (product switch in flight); next aim will retry.
    } finally {
      _cursorBusy = false;
    }
  }

  // -------------------------------------------------------------- tools ----

  /// Write the current radar image to ~/Pictures/taa-yuku-radar. Named apart
  /// from the `saveSnapshot` it calls: a method of the same name would win
  /// over the library function inside this class and recurse.
  String? saveFrameSnapshot() {
    final frame = _displayFrame;
    if (frame == null) return null;
    try {
      final f = saveSnapshot(
        Uint8List.fromList(frame.meta.png),
        '${_product.isMrms ? 'MRMS' : _site.icao}_${_product.short}'
            .replaceAll(' ', ''),
      );
      return f.path;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return null;
    }
  }

  /// Open the 3D volume view on the Level 2 volume for this site, at the
  /// moment currently being shown.
  ///
  /// `before` matters: without it replay showed the chosen time on the map
  /// while 3D silently jumped to now, which is worse than not replaying at
  /// all because nothing on screen says the two disagree.
  Future<void> open3D() async {
    setState(() => _loading = true);
    widget.onChanged();
    try {
      final keys = await listRecentVolumes(
        _site.icao,
        count: 1,
        before: widget.shared.historyTime,
      );
      if (keys.isEmpty) throw Exception('no volume for ${_site.icao}');
      final bytes = _l2Cache[keys.last] ?? await fetchVolume(keys.last);
      _l2Cache[keys.last] = bytes;
      if (!mounted) return;
      setState(() => _loading = false);
      widget.onChanged();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Volume3DScreen(
            volumeBytes: bytes,
            siteId: _site.icao,
            basemapUrl: widget.shared.basemap.url,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      widget.onChanged();
    }
  }

  void _onMeasureTap(LatLng p) {
    setState(() {
      if (_measurePts.length >= 2) _measurePts.clear();
      _measurePts.add(p);
    });
  }

  Future<void> _inspect(LatLng p) async {
    if (_frames.isEmpty || _product.isMrms) return;
    final frame = _frames[_shownFrame];
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
      if (!mounted) return;
      setState(() {
        _samplePos = p;
        _sampleText = s.distanceKm <= 0
            ? 'outside radar coverage'
            : '$valueText  ·  ${s.distanceKm.toStringAsFixed(0)} km'
                '  ·  beam ${beamKft.toStringAsFixed(1)} kft';
      });
      _sampleClear?.cancel();
      _sampleClear = Timer(const Duration(seconds: 8), () {
        if (mounted) {
          setState(() {
            _sampleText = null;
            _samplePos = null;
          });
        }
      });
    } catch (_) {
      // Sampling is best-effort.
    }
  }

  // ------------------------------------------------------------- render ----

  /// Beam center height above the radar (meters) at a slant range, using
  /// the standard 4/3-earth refraction model.
  double _beamHeightM(double rangeM, double elevationDeg) {
    const keR = 6371000.0 * 4.0 / 3.0;
    final el = elevationDeg * math.pi / 180.0;
    return math.sqrt(
          rangeM * rangeM + keR * keR + 2 * rangeM * keR * math.sin(el),
        ) -
        keR;
  }

  /// Great-circle distance (km) and initial bearing (deg) between two points.
  (double, double) _distanceBearing(LatLng a, LatLng b) {
    const r = 6371.0;
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final dLat = la2 - la1;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final d = 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
    final y = math.sin(dLon) * math.cos(la2);
    final x = math.cos(la1) * math.sin(la2) -
        math.sin(la1) * math.cos(la2) * math.cos(dLon);
    var brg = math.atan2(y, x) * 180 / math.pi;
    if (brg < 0) brg += 360;
    return (d, brg);
  }

  /// Visible box expanded slightly, clipped to the data extent, plus the
  /// pixel size to render it at.
  ({double n, double s, double e, double w, int width, int height})?
      _viewBox() {
    if (_frames.isEmpty || !mounted || !_mapReady) return null;
    if (_paneSize.width <= 0) return null;
    final cam = _mapController.camera;
    final vis = cam.visibleBounds;
    final dLat = (vis.north - vis.south) * 0.25;
    final dLon = (vis.east - vis.west) * 0.25;
    var north = vis.north + dLat;
    var south = vis.south - dLat;
    var east = vis.east + dLon;
    var west = vis.west - dLon;
    final d = _frames.first.dataBounds;
    north = math.min(north, d.north);
    south = math.max(south, d.south);
    east = math.min(east, d.east);
    west = math.max(west, d.west);
    if (north <= south || east <= west) return null;

    // Pixel size: match this pane's on-screen density, capped to keep
    // renders fast. Four panes at a quarter of the area each therefore ask
    // for a quarter of the pixels, rather than four full-window renders.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final pxPerLon = _paneSize.width * dpr / (vis.east - vis.west);
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
  Future<void> _renderFuture() async {
    if (!_future || _futureBusy) return;
    if (_product.isLevel2) {
      setState(() => _error = 'Future radar needs a Level 3 or mosaic product');
      widget.onChanged();
      return;
    }
    if (_frames.length < 2) {
      // Need a previous scan to measure motion against.
      if (widget.shared.frameCount < 4) {
        widget.shared.setFrameCount(4);
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
      if (!mounted || !_future) return;
      final img = MemoryImage(Uint8List.fromList(r.png));
      // ignore: use_build_context_synchronously
      await precacheImage(img, context);
      if (!mounted || !_future) return;
      setState(() => _futureFrame = _Frame(r, img, Uint8List(0)));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _futureBusy = false;
    }
  }

  /// Zoomed out past a single radar's useful range, hand over to the
  /// national mosaic; zoom back in and the site radar returns.
  ///
  /// Only in the single-pane layout. In a multi-panel comparison this would
  /// be actively hostile: zooming out to see the whole line would silently
  /// replace the velocity and dual-pol panes with four copies of the same
  /// mosaic, throwing away the arrangement the user built.
  void _maybeSwitchMosaic() {
    if (_loading || !_mapReady) return;
    if (widget.shared.layout != PaneLayout.single) return;
    final z = _mapController.camera.zoom;
    if (z < 6.0 && identical(_product, productRef)) {
      setProduct(mrmsProduct);
    } else if (z >= 6.5 && _product.isMrms) {
      setProduct(productRef);
    }
  }

  /// Re-render all loaded frames for the current viewport at (roughly)
  /// screen resolution, so 250 m gates stay sharp when zoomed in.
  Future<void> _renderViewport() async {
    if (_frames.isEmpty || !mounted) return;
    final box = _viewBox();
    if (box == null) return;
    final generation = ++_viewGeneration;
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
      if (generation != _viewGeneration || !mounted) return;
      final newBounds = LatLngBounds(
        LatLng(box.n, box.w),
        LatLng(box.s, box.e),
      );
      for (var i = 0; i < _frames.length; i++) {
        // ignore: use_build_context_synchronously
        await precacheImage(results[i], context);
        _frames[i].image = results[i];
        _frames[i].bounds = newBounds;
      }
      if (generation != _viewGeneration || !mounted) return;
      setState(() {});
      if (_future) unawaited(_renderFuture());
    } catch (_) {
      // Viewport sharpening is best-effort; the full-disk render stays up.
    }
  }

  CircleMarker _strikeCircle(Strike s) {
    final ageMin = DateTime.now().toUtc().difference(s.time).inSeconds / 60.0;
    // Fresh strikes: bright white-yellow; fading to dim orange over 20 min.
    final t = (ageMin / 20.0).clamp(0.0, 1.0);
    final color = Color.lerp(
      const Color(0xFFFFF59D),
      const Color(0x66E65100),
      t,
    )!;
    return CircleMarker(
      point: s.pos,
      radius: ageMin < 2 ? 3.5 : 2.5,
      color: color,
    );
  }

  // ----------------------------------------------------------------- ui ----

  @override
  Widget build(BuildContext context) {
    final shared = widget.shared;
    final frame = _displayFrame;

    return LayoutBuilder(builder: (context, constraints) {
      // Recording the pane's size here is what lets viewport re-renders ask
      // for the right number of pixels. A changed size also invalidates the
      // current render, so kick off a fresh one.
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size != _paneSize) {
        final had = _paneSize;
        _paneSize = size;
        if (had != Size.zero) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_renderViewport());
          });
        }
      }

      return MouseRegion(
        onEnter: (_) {
          if (!widget.focused) widget.onFocus();
        },
        child: Listener(
          // Focus follows any press too, so a tap in a pane makes the
          // toolbar act on that pane even when the pointer never moved.
          onPointerDown: (_) {
            if (!widget.focused) widget.onFocus();
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.focused && widget.showHeader
                    ? Wx.accent
                    : Wx.line,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: _map(shared, frame)),
                if (widget.showHeader)
                  Positioned(top: 0, left: 0, right: 0, child: _header(shared)),
                if (_loading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                // Same edge, same toggle. A classified field gets a list of
                // classes rather than a colour scale: the scale would be
                // labelled with class ids, which are not a quantity and mean
                // nothing to read off. The colours are the NWS's own, not our
                // 3D classifier's, because this is their product on screen.
                if (shared.showKey &&
                    (_product.short == 'HCA' || _keyScale != null))
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _product.short == 'HCA'
                          ? const HydroLegend(classes: nwsHydrometeorClasses)
                          : ColorKey(
                              scale: _keyScale!,
                              rangeFolded: _product.short.contains('VEL') ||
                                  _product.short.contains('SRM'),
                            ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _readouts(),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// The pane's own label: which radar, which product, what time. Without
  /// this a 2x2 is four anonymous maps.
  Widget _header(WorkspaceState shared) {
    final t = frameTime;
    final el = elevationDeg;
    final age = dataAge;
    final stale = age != null && age.inMinutes > 20 && shared.historyTime == null;

    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: Wx.bg1.withValues(alpha: 0.88),
      child: Row(
        children: [
          Text(
            _product.isMrms ? 'CONUS' : _site.icao,
            style: Wx.label.copyWith(
              fontWeight: FontWeight.w700,
              color: widget.focused ? Wx.accent : Wx.text,
            ),
          ),
          const SizedBox(width: 6),
          Text(_product.bareShort, style: Wx.labelDim),
          if (el != null) ...[
            const SizedBox(width: 5),
            Text('${el.toStringAsFixed(1)}°', style: Wx.labelDim),
          ],
          const Spacer(),
          if (stale)
            const Padding(
              padding: EdgeInsets.only(right: 5),
              child: Icon(Icons.schedule, size: 12, color: Wx.warn),
            ),
          if (_error != null)
            Tooltip(
              message: _error!,
              child: const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.error_outline, size: 12, color: Wx.warn),
              ),
            ),
          Text(
            t == null ? '—' : DateFormat('HH:mm').format(t.toLocal()),
            style: Wx.mono.copyWith(
              color: stale ? Wx.warn : Wx.textDim,
            ),
          ),
        ],
      ),
    );
  }

  Widget _map(WorkspaceState shared, _Frame? frame) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: widget.initialCenter ?? LatLng(_site.lat, _site.lon),
        initialZoom: widget.initialZoom ?? 7,
        minZoom: 3,
        maxZoom: 15,
        onMapReady: () => _mapReady = true,
        onTap: (tapPos, latlng) {
          if (_measuring) _onMeasureTap(latlng);
          if (_cursor) unawaited(_aimCursor(latlng, fromTap: true));
        },
        onPointerHover: (event, latlng) {
          if (_cursor) unawaited(_aimCursor(latlng));
        },
        onLongPress: (tapPos, latlng) => unawaited(_inspect(latlng)),
        // Pinch-zoom and drag, but no accidental two-finger rotation:
        // a twisted radar map is disorienting and hard to undo on touch.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapEvent: (evt) {
          _maybeSwitchMosaic();
          // Only a real gesture propagates to the linked panes. Echoing a
          // move that arrived from another pane is how view linking turns
          // into an infinite loop between two maps.
          if (evt.source != MapEventSource.mapController &&
              evt.source != MapEventSource.fitCamera) {
            widget.onCameraMoved(
              widget.paneId,
              evt.camera.center,
              evt.camera.zoom,
            );
          }
          _viewDebounce?.cancel();
          // Only the radar image depends on the viewport. Storm tracks are
          // positioned by azimuth and range from the site, so panning and
          // zooming cannot change where they are — and refetching on every
          // gesture would be network for nothing.
          _viewDebounce = Timer(
            const Duration(milliseconds: 350),
            () => unawaited(_renderViewport()),
          );
        },
        backgroundColor: Wx.bg0,
      ),
      children: [
        TileLayer(
          urlTemplate: shared.basemap.url,
          userAgentPackageName: appId,
        ),
        if (frame != null)
          OverlayImageLayer(
            overlayImages: [
              OverlayImage(
                bounds: frame.bounds,
                imageProvider: frame.image,
                gaplessPlayback: true,
              ),
            ],
          ),
        if (shared.showOutlook)
          PolygonLayer(
            polygons: [
              for (final a in shared.outlook)
                for (final ring in a.polygons)
                  Polygon(
                    points: ring,
                    color: a.color.withValues(alpha: 0.16),
                    borderColor: a.color.withValues(alpha: 0.9),
                    borderStrokeWidth: 1.5,
                  ),
            ],
          ),
        GestureDetector(
          onTap: () {
            final hit = _alertHit.value;
            if (hit != null && hit.hitValues.isNotEmpty) {
              showAlertSheet(context, hit.hitValues.first);
            }
          },
          child: PolygonLayer(
            hitNotifier: _alertHit,
            polygons: [
              for (final a in shared.alerts)
                if (shared.alertLayers.contains(a.category))
                  for (final ring in a.polygons)
                    Polygon(
                      points: ring,
                      hitValue: a,
                      // Watches and advisories sit under the warnings
                      // rather than competing with them.
                      color: a.color.withValues(
                        alpha:
                            a.category == AlertCategory.warning ? 0.12 : 0.07,
                      ),
                      borderColor: a.color.withValues(
                        alpha:
                            a.category == AlertCategory.warning ? 1.0 : 0.75,
                      ),
                      borderStrokeWidth:
                          a.category == AlertCategory.warning ? 2 : 1.2,
                    ),
            ],
          ),
        ),
        if (shared.showLightning)
          CircleLayer(
            circles: [for (final s in shared.strikes) _strikeCircle(s)],
          ),
        if (shared.showReports)
          MarkerLayer(
            markers: [
              for (final r in shared.reports)
                Marker(
                  point: r.pos,
                  width: 16,
                  height: 16,
                  child: GestureDetector(
                    onTap: () => ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 5),
                          content: Text(
                            '${r.time}Z  ${r.detail} — ${r.location}',
                          ),
                        ),
                      ),
                    child: Icon(
                      r.kind == 'tornado'
                          ? Icons.cyclone
                          : r.kind == 'hail'
                              ? Icons.ac_unit
                              : Icons.air,
                      size: 15,
                      color: r.color,
                      shadows: const [
                        Shadow(blurRadius: 3, color: Colors.black),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        if (_cursor && _cursorPos != null && _cursorSite != null) ...[
          CircleLayer(
            circles: [
              CircleMarker(
                point: _cursorSite!,
                // Geometric, so the ring always passes exactly through the
                // crosshair — even outside radar coverage, where there is no
                // sample to take a distance from.
                radius: _distanceBearing(_cursorSite!, _cursorPos!).$1 * 1000,
                useRadiusInMeter: true,
                color: Colors.transparent,
                borderColor: Wx.warn.withValues(alpha: 0.85),
                borderStrokeWidth: 1.5,
              ),
            ],
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: [_cursorSite!, _cursorPos!],
                color: Wx.warn.withValues(alpha: 0.9),
                strokeWidth: 1.5,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: _cursorPos!,
                width: 26,
                height: 26,
                child: IgnorePointer(
                  child: Icon(
                    _cursorPinned ? Icons.gps_fixed : Icons.add,
                    size: _cursorPinned ? 22 : 26,
                    color: Wx.warn,
                    shadows: const [
                      Shadow(blurRadius: 3, color: Colors.black),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_measurePts.length == 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _measurePts,
                color: Wx.accent,
                strokeWidth: 2,
              ),
            ],
          ),
        if (_measuring)
          MarkerLayer(
            markers: [
              for (final p in _measurePts)
                Marker(
                  point: p,
                  width: 12,
                  height: 12,
                  child: const Icon(Icons.circle, size: 10, color: Wx.accent),
                ),
            ],
          ),
        if (_samplePos != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _samplePos!,
                width: 18,
                height: 18,
                child: const Icon(
                  Icons.add_circle_outline,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        if (_tracks) ...[
          // Projected path, then the cell itself on top of it.
          PolylineLayer(
            polylines: [
              for (final s in _stormTracks)
                if (s.forecast.isNotEmpty)
                  Polyline(
                    points: [
                      LatLng(s.lat, s.lon),
                      for (final f in s.forecast) LatLng(f.lat, f.lon),
                    ],
                    color: Colors.white.withValues(alpha: 0.85),
                    strokeWidth: 2,
                  ),
            ],
          ),
          MarkerLayer(
            markers: [
              for (final s in _stormTracks) ...[
                for (final f in s.forecast)
                  Marker(
                    point: LatLng(f.lat, f.lon),
                    width: 30,
                    height: 14,
                    child: Text(
                      '${f.minutes.round()}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 3, color: Colors.black)],
                      ),
                    ),
                  ),
                Marker(
                  point: LatLng(s.lat, s.lon),
                  width: 108,
                  height: 34,
                  child: GestureDetector(
                    onTap: () => _showTrackSheet(s),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          s.tracked
                              ? Icons.change_history
                              : Icons.circle_outlined,
                          size: 14,
                          color: Wx.warn,
                        ),
                        Text(
                          s.tracked
                              ? '${s.id} · ${s.speedKt.round()} kt'
                              : '${s.id} · new',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            shadows: [
                              Shadow(blurRadius: 3, color: Colors.black),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          MarkerLayer(
            markers: [
              for (final m in _mesos)
                Marker(
                  point: LatLng(m.lat, m.lon),
                  width: 74,
                  height: 40,
                  child: GestureDetector(
                    onTap: () => _showMesoSheet(m),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          m.tvs ? Icons.warning : Icons.rotate_right,
                          size: 20,
                          color: m.tvs ? Wx.danger : Colors.pinkAccent,
                        ),
                        Text(
                          m.tvs ? 'TVS' : 'MESO ${m.rank}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: m.tvs ? Wx.danger : Colors.pinkAccent,
                            shadows: const [
                              Shadow(blurRadius: 3, color: Colors.black),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
        MarkerLayer(
          markers: [
            for (final s in nexradSites)
              if (!s.isTdwr)
                Marker(
                  point: LatLng(s.lat, s.lon),
                  width: 10,
                  height: 10,
                  child: GestureDetector(
                    onTap: () => selectSite(s, moveMap: true),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.icao == _site.icao ? Wx.accent : Colors.white24,
                        border: Border.all(color: Colors.black45),
                      ),
                    ),
                  ),
                ),
            if (shared.myLocation != null)
              Marker(
                point: shared.myLocation!,
                width: 14,
                height: 14,
                child: const Icon(
                  Icons.my_location,
                  size: 14,
                  color: Color(0xFF64B5F6),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Tool readouts, stacked at the foot of the pane. Each only appears while
  /// its tool is on, so an idle pane is all map.
  Widget _readouts() {
    final rows = <Widget>[];

    if (_future) {
      rows.add(
        Container(
          height: 30,
          padding: const EdgeInsets.only(left: 8, right: 4),
          color: Wx.bg1.withValues(alpha: 0.92),
          child: Row(
            children: [
              const Icon(Icons.fast_forward, size: 13, color: Wx.good),
              const SizedBox(width: 6),
              Text(
                _futureMinutes == 0 ? 'now' : '+${_futureMinutes.round()} min',
                style: Wx.mono.copyWith(color: Wx.good),
              ),
              Expanded(
                child: Slider(
                  value: _futureMinutes,
                  max: 60,
                  divisions: 12,
                  onChanged: (v) => setState(() => _futureMinutes = v),
                  onChangeEnd: (_) => unawaited(_renderFuture()),
                ),
              ),
              const Text('forecast', style: Wx.labelDim),
            ],
          ),
        ),
      );
    }

    if (_cursor && _cursorPos != null && _cursorSample != null) {
      final c = _cursorSample!;
      final value = c.rangeFolded
          ? 'RF'
          : c.value == null
              ? '—'
              : '${c.value!.toStringAsFixed(1)} ${c.unit}'.trim();
      // Range and heading come from the cursor's actual position so they
      // always agree with the ring; the sample supplies the value and the
      // sweep's elevation.
      final site = _cursorSite;
      final (km, brg) = site == null
          ? (c.distanceKm, c.azimuthDeg)
          : _distanceBearing(site, _cursorPos!);
      final kft = _beamHeightM(km * 1000, c.elevationDeg) * 3.28084 / 1000.0;
      rows.add(
        _readoutBar(
          accent: Wx.warn,
          leading: _cursorPinned ? Icons.push_pin : Icons.ads_click,
          value: value,
          detail: '${km.toStringAsFixed(1)} km '
              '(${(km * 0.621371).toStringAsFixed(1)} mi)'
              '  ·  ${brg.round()}°'
              '  ·  ${kft.toStringAsFixed(1)} kft'
              '  @ ${c.elevationDeg.toStringAsFixed(1)}°',
        ),
      );
    }

    if (_measurePts.length == 2) {
      final (d, b) = _distanceBearing(_measurePts[0], _measurePts[1]);
      rows.add(
        _readoutBar(
          accent: Wx.accent,
          leading: Icons.straighten,
          value: '${d.toStringAsFixed(1)} km',
          detail: '(${(d * 0.621371).toStringAsFixed(1)} mi)  ·  ${b.round()}°',
        ),
      );
    }

    final sample = _sampleText;
    if (sample != null) {
      rows.add(
        _readoutBar(
          accent: Wx.textDim,
          leading: Icons.center_focus_weak,
          value: '',
          detail: sample,
        ),
      );
    }

    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _readoutBar({
    required Color accent,
    required IconData leading,
    required String value,
    required String detail,
  }) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Wx.bg1.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: accent.withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          Icon(leading, size: 12, color: accent),
          const SizedBox(width: 6),
          if (value.isNotEmpty) ...[
            Text(
              value,
              style: Wx.mono.copyWith(color: accent, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              detail,
              overflow: TextOverflow.ellipsis,
              style: Wx.mono,
            ),
          ),
        ],
      ),
    );
  }

  /// Detail for one storm cell.
  void _showTrackSheet(StormTrack s) {
    final dir = ((s.headingDeg / 22.5).round() % 16);
    const pts = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Storm cell ${s.id}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Wx.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.tracked
                    ? 'Moving toward ${pts[dir]} '
                        '(${s.headingDeg.round()}°) at '
                        '${s.speedKt.round()} kt'
                    : 'The NWS has no movement solution for this cell yet, '
                        'so it has no track.',
                style: const TextStyle(
                  color: Wx.text,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              if (s.tracked && s.errorNm > 0)
                Text(
                  'NWS forecast track error: ${s.errorNm} NM',
                  style: const TextStyle(color: Wx.textDim, fontSize: 12.5),
                ),
              if (s.tracked) ...[
                const SizedBox(height: 10),
                const Text(
                  'Positions are the NWS forecast, which assumes the cell '
                  'keeps its current speed and direction. Storms turn, split '
                  'and decay; treat the far end of the track as a hint.',
                  style: TextStyle(
                    color: Wx.textFaint,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Detail for one mesocyclone.
  void _showMesoSheet(MesoHit m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.tvs
                    ? 'Tornado vortex signature'
                    : 'Mesocyclone · rank ${m.rank}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: m.tvs ? Wx.danger : Colors.pinkAccent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Circulation ${m.id}'
                '${m.stormId.isEmpty ? '' : ' · storm ${m.stormId}'}',
                style: const TextStyle(color: Wx.text, fontSize: 12.5),
              ),
              const SizedBox(height: 4),
              Text(
                'Peak rotational velocity ${m.maxRvKt.round()} kt'
                '${m.msi >= 0 ? '  ·  strength index ${m.msi}' : ''}',
                style: const TextStyle(color: Wx.text, fontSize: 12.5),
              ),
              if (m.motion.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motion ${m.motion} (deg/kt, as the product reports it)',
                  style: const TextStyle(color: Wx.text, fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                m.tvs
                    ? 'The NWS tornado vortex signature algorithm fired on '
                        'this circulation. That is a radar signature, not a '
                        'confirmed tornado, and it is not a warning — always '
                        'follow official NWS warnings.'
                    : 'Detected by the NWS Mesocyclone Detection Algorithm, '
                        'which requires rotation to persist through depth and '
                        'between volumes. Rank 5 and above is treated as '
                        'significant.',
                style: const TextStyle(
                  color: Wx.textFaint,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
