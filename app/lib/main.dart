import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'data/alerts_fetcher.dart';
import 'data/glm_fetcher.dart';
import 'data/level2_fetcher.dart';
import 'data/level3_fetcher.dart';
import 'data/lightning.dart';
import 'data/mrms_fetcher.dart';
import 'data/spc_fetcher.dart';
import 'data/user_files.dart';
import 'data/locate.dart';
import 'data/nexrad_sites.g.dart';
import 'src/rust/api/radar.dart';
import 'src/rust/frb_generated.dart';
import 'ui/volume3d_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const RadarApp());
}

class RadarApp extends StatelessWidget {
  const RadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF29B6F6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RadarScreen(),
    );
  }
}

/// One product on offer in the UI. Level 3 tilted products map to mnemonics
/// like N0B/N1B/N2B/N3B (tilt digit in the middle); Level 2 products carry a
/// moment name and decode full Archive II volumes on-device.
class _Product {
  final String label;
  final String short;
  final String? tiltSuffix;
  final String? fixedCode;
  final String? l2Moment;

  /// Volume-integrated Level 2 products have no tilt dimension.
  final bool l2Volume;

  /// National MRMS mosaic: one grid for the whole country, no radar site.
  final bool isMrms;
  const _Product(
    this.label,
    this.short, {
    this.tiltSuffix,
    this.fixedCode,
    this.l2Moment,
    this.l2Volume = false,
    this.isMrms = false,
  });

  bool get isLevel2 => l2Moment != null;
  bool get hasTilts => tiltSuffix != null || (isLevel2 && !l2Volume);
  String code(int tilt) => fixedCode ?? 'N$tilt$tiltSuffix';
}

const _mrmsProduct =
    _Product('National Mosaic', 'MRMS', isMrms: true);

const _l3Products = [
  _Product('Reflectivity', 'REF', tiltSuffix: 'B'),
  _Product('Velocity', 'VEL', tiltSuffix: 'G'),
  _Product('Differential Reflectivity', 'ZDR', tiltSuffix: 'X'),
  _Product('Correlation Coefficient', 'CC', tiltSuffix: 'C'),
  _Product('Specific Differential Phase', 'KDP', tiltSuffix: 'K'),
  _Product('Hydrometeor Classification', 'HCA', tiltSuffix: 'H'),
  _Product('Storm Total Precip', 'STP', fixedCode: 'DTA'),
];

const _l2Products = [
  _Product('Reflectivity', 'L2 REF', l2Moment: 'REF'),
  _Product('Velocity', 'L2 VEL', l2Moment: 'VEL'),
  _Product('Storm-Relative Velocity', 'L2 SRM', l2Moment: 'SRM'),
  _Product('Rotation (Az. Shear)', 'L2 ROT', l2Moment: 'ROT'),
  _Product('Spectrum Width', 'L2 SW', l2Moment: 'SW'),
  _Product('Differential Reflectivity', 'L2 ZDR', l2Moment: 'ZDR'),
  _Product('Correlation Coefficient', 'L2 CC', l2Moment: 'RHO'),
];

/// On-device derived products, computed from the full Level 2 volume.
const _derivedProducts = [
  _Product('Composite Reflectivity', 'CREF', l2Moment: 'CREF', l2Volume: true),
  _Product('Vert. Integrated Liquid', 'VIL', l2Moment: 'VIL', l2Volume: true),
  _Product('Echo Tops', 'ET', l2Moment: 'ET', l2Volume: true),
];

class _Basemap {
  final String label;
  final String url;
  final String attribution;
  const _Basemap(this.label, this.url, this.attribution);
}

const _basemaps = [
  _Basemap(
    'Dark',
    'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    '© OpenStreetMap © CARTO',
  ),
  _Basemap(
    'OpenStreetMap',
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap contributors',
  ),
  _Basemap(
    'Satellite',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Imagery © Esri',
  ),
  _Basemap(
    'Topographic',
    'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap © OpenTopoMap (CC-BY-SA)',
  ),
];

enum _LightningSource { off, blitzortung, glm, both }

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

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  final _mapController = MapController();

  NexradSite _site = nexradSites.firstWhere((s) => s.icao == 'KTLX');
  _Product _product = _l3Products[0];
  int _tilt = 0;
  _Basemap _basemap = _basemaps[0];
  LatLng? _myLocation;

  /// How many animation frames to load. 1 = just the latest scan (default,
  /// fastest); more enables the loop.
  int _frameCount = 1;

  List<_Frame> _frames = [];
  int _frameIndex = 0;
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
  Timer? _alertTimer;
  final LayerHitNotifier<WeatherAlert> _alertHit = ValueNotifier(null);
  final Map<String, Uint8List> _l2Cache = {};

  final _blitz = BlitzortungClient();
  final _glm = GlmClient();
  final List<Strike> _strikes = [];
  _LightningSource _lightning = _LightningSource.off;
  StreamSubscription<Strike>? _strikeSub;
  StreamSubscription<Strike>? _glmSub;
  Timer? _strikeTimer;
  bool _strikesDirty = false;

  bool get _showLightning => _lightning != _LightningSource.off;

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
  _Frame? _futureFrame;
  bool _futureBusy = false;

  @override
  void initState() {
    super.initState();
    _startup();
    _startAnimation();
    _loadAlerts();
    _alertTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _loadAlerts(),
    );
  }

  Future<void> _startup() async {
    // Find where we are (IP-based on desktop; GPS on mobile later) and tune
    // to the nearest radar. Falls back to the default site silently.
    final loc = await locate();
    if (loc != null && mounted) {
      _myLocation = loc;
      final nearest = _nearestSite(loc);
      setState(() => _site = nearest);
      _mapController.move(loc, 7);
    }
    await _loadFrames();
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _alertTimer?.cancel();
    _strikeTimer?.cancel();
    _strikeSub?.cancel();
    _glmSub?.cancel();
    _sampleClear?.cancel();
    _blitz.stop();
    _glm.stop();
    super.dispose();
  }

  // --------------------------------------------------------------- data ----

  Future<void> _loadAlerts() async {
    try {
      final alerts = await fetchActiveAlerts();
      if (!mounted) return;
      setState(() => _alerts = alerts);
    } catch (_) {
      // Alerts are supplementary; keep the last good set on failure.
    }
  }

  Future<void> _loadOutlook() async {
    if (_outlook.isNotEmpty) return;
    try {
      final o = await fetchOutlook();
      if (mounted) setState(() => _outlook = o);
    } catch (_) {}
  }

  Future<void> _loadReports() async {
    if (_reports.isNotEmpty) return;
    try {
      final r = await fetchStormReports();
      if (mounted) setState(() => _reports = r);
    } catch (_) {}
  }

  void _startAnimation() {
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (!_playing || _frames.length < 2) return;
      setState(() {
        // Dwell on the newest frame for a few ticks before looping.
        if (_frameIndex >= _frames.length - 1 + 3) {
          _frameIndex = 0;
        } else {
          _frameIndex++;
        }
      });
    });
  }

  int get _shownFrame =>
      _frames.isEmpty ? 0 : math.min(_frameIndex, _frames.length - 1);

  Future<void> _loadFrames() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
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
        _frameIndex = frames.length - 1;
        _playing = frames.length > 1;
        _loading = false;
      });
      // Sharpen for the current viewport right away.
      unawaited(_renderViewport());
      if (_cursor) unawaited(_openCursorSession());
    } catch (e) {
      if (generation != _loadGeneration || !mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<List<_Frame>> _loadLevel3Frames() async {
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
      return _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes);
    }));
  }

  /// The national mosaic is one CONUS grid per file; decode covers the whole
  /// country, so the initial render just uses the grid's own bounds.
  Future<List<_Frame>> _loadMrmsFrames() async {
    final keys = await listRecentMosaics(
      count: math.min(_frameCount, 6),
      before: _historyTime,
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
      frames
          .add(_Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes));
    }
    return frames;
  }

  /// Level 2 volumes are big (5-15 MB), so cap the loop length and cache the
  /// raw bytes so tilt/moment switches don't re-download.
  Future<List<_Frame>> _loadLevel2Frames() async {
    final count = math.min(_frameCount, 4);
    final keys = await listRecentVolumes(
      _site.icao,
      count: count,
      before: _historyTime,
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
      frames
          .add(_Frame(frame, MemoryImage(Uint8List.fromList(frame.png)), bytes));
    }
    while (_l2Cache.length > 6) {
      _l2Cache.remove(_l2Cache.keys.first);
    }
    return frames;
  }

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
      if (_cursorPinned && existing != null) {
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
    if (_cursorBusy || now.difference(_cursorLast).inMilliseconds < 60) return;
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

  /// Jump the whole app to a past moment (or back to live).
  Future<void> _pickHistory() async {
    if (_historyTime != null) {
      setState(() {
        _historyTime = null;
        _frames = [];
      });
      _loadFrames();
      return;
    }
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1991),
      lastDate: now,
      helpText: 'Replay a past storm',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
      helpText: 'Local time to replay',
    );
    if (time == null || !mounted) return;
    setState(() {
      _historyTime = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _frames = [];
      _l2Cache.clear();
    });
    _loadFrames();
  }

  /// Write the current radar image to ~/Pictures/radar-app.
  Future<void> _saveSnapshot() async {
    final frame = _future && _futureFrame != null
        ? _futureFrame
        : (_frames.isEmpty ? null : _frames[_shownFrame]);
    if (frame == null) return;
    try {
      final f = saveSnapshot(
        Uint8List.fromList(frame.meta.png),
        '${_product.isMrms ? 'MRMS' : _site.icao}_${_product.short}'
            .replaceAll(' ', ''),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Saved ${f.path}')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Apply a GRLevelX .pal file (or clear back to the built-ins).
  Future<void> _applyPalette(String path) async {
    try {
      if (path.isEmpty) {
        await resetPalettes();
      } else {
        final kind = await installPalette(text: File(path).readAsStringSync());
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(content: Text('Palette applied to $kind')),
            );
        }
      }
      _futureFrame = null;
      await _loadFrames();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onMeasureTap(LatLng p) {
    setState(() {
      if (_measurePts.length >= 2) _measurePts.clear();
      _measurePts.add(p);
    });
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
  ({double n, double s, double e, double w, int width, int height})? _viewBox() {
    if (_frames.isEmpty || !mounted) return null;
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

    final media = MediaQuery.of(context);
    final pxPerLon = media.size.width * media.devicePixelRatio /
        (vis.east - vis.west);
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
      return;
    }
    if (_frames.length < 2) {
      // Need a previous scan to measure motion against.
      setState(() => _frameCount = math.max(_frameCount, 4));
      await _loadFrames();
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
  /// national mosaic; zoom back in and the site radar returns. Only the
  /// default reflectivity view participates — an explicitly chosen product
  /// is never swapped out from under the user.
  void _maybeSwitchMosaic() {
    if (_loading) return;
    final z = _mapController.camera.zoom;
    if (z < 6.0 && _product == _l3Products[0]) {
      setState(() {
        _product = _mrmsProduct;
        _frames = [];
      });
      _loadFrames();
    } else if (z >= 6.5 && _product.isMrms) {
      setState(() {
        _product = _l3Products[0];
        _frames = [];
      });
      _loadFrames();
    }
  }

  /// Re-render all loaded frames for the current viewport at (roughly)
  /// screen resolution, so 250 m gates stay sharp when zoomed in.
  Future<void> _renderViewport() async {
    if (_frames.isEmpty || !mounted) return;
    final generation = ++_viewGeneration;
    final cam = _mapController.camera;
    final vis = cam.visibleBounds;

    // Expand by 25% so small pans don't immediately show missing edges.
    final dLat = (vis.north - vis.south) * 0.25;
    final dLon = (vis.east - vis.west) * 0.25;
    var north = vis.north + dLat;
    var south = vis.south - dLat;
    var east = vis.east + dLon;
    var west = vis.west - dLon;

    // Clip to the radar's data disk.
    final d = _frames.first.dataBounds;
    north = math.min(north, d.north);
    south = math.max(south, d.south);
    east = math.min(east, d.east);
    west = math.max(west, d.west);
    if (north <= south || east <= west) return; // disk not in view

    // Pixel size: match on-screen density, capped to keep renders fast.
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final pxPerLon = media.size.width * dpr / (vis.east - vis.west);
    final width = ((east - west) * pxPerLon).round().clamp(256, 2200);
    // Height follows the Mercator aspect of the box.
    double mercY(double latDeg) {
      final lat = latDeg * math.pi / 180.0;
      return math.log(math.tan(math.pi / 4 + lat / 2));
    }

    final aspect =
        (mercY(north) - mercY(south)) / ((east - west) * math.pi / 180.0);
    final height = (width * aspect).round().clamp(256, 2200);

    try {
      final results = await Future.wait(_frames.map((f) async {
        final r = _product.isMrms
            ? await renderMrmsView(
                data: f.raw,
                north: north,
                south: south,
                east: east,
                west: west,
                width: width,
                height: height,
              )
            : _product.isLevel2
            ? await renderLevel2View(
                data: f.raw,
                moment: _product.l2Moment!,
                elevationIndex: _product.hasTilts ? _tilt : 0,
                north: north,
                south: south,
                east: east,
                west: west,
                width: width,
                height: height,
              )
            : await renderLevel3View(
                data: f.raw,
                north: north,
                south: south,
                east: east,
                west: west,
                width: width,
                height: height,
              );
        return MemoryImage(Uint8List.fromList(r.png));
      }));
      if (generation != _viewGeneration || !mounted) return;
      final newBounds = LatLngBounds(LatLng(north, west), LatLng(south, east));
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

  // -------------------------------------------------------------- sites ----

  void _selectSite(NexradSite site, {bool moveMap = false}) {
    if (site.icao == _site.icao) return;
    setState(() {
      _site = site;
      _frames = [];
    });
    if (moveMap) {
      _mapController.move(
        LatLng(site.lat, site.lon),
        _mapController.camera.zoom,
      );
    }
    _loadFrames();
  }

  NexradSite _nearestSite(LatLng p) {
    NexradSite best = nexradSites.first;
    double bestD = double.infinity;
    for (final s in nexradSites) {
      if (s.isTdwr) continue; // TDWR products come in a later phase
      final d = _dist2(p.latitude, p.longitude, s.lat, s.lon);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  // Squared equirectangular distance — plenty for "which site is closest".
  double _dist2(double lat1, double lon1, double lat2, double lon2) {
    final dy = lat1 - lat2;
    final dx = (lon1 - lon2) * math.cos(lat1 * math.pi / 180.0);
    return dy * dy + dx * dx;
  }

  Future<void> _goToMyLocation() async {
    _myLocation ??= await locate();
    final loc = _myLocation;
    if (loc == null) return;
    _mapController.move(loc, 8);
    final nearest = _nearestSite(loc);
    if (nearest.icao != _site.icao) {
      _selectSite(nearest);
    }
  }

  // ---------------------------------------------------------- lightning ----

  void _setLightning(_LightningSource src) {
    setState(() => _lightning = src);
    final useBlitz =
        src == _LightningSource.blitzortung || src == _LightningSource.both;
    final useGlm = src == _LightningSource.glm || src == _LightningSource.both;

    if (useBlitz) {
      _blitz.start();
      _strikeSub ??= _blitz.strikes.listen((s) {
        _strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _blitz.stop();
    }
    if (useGlm) {
      _glm.start();
      _glmSub ??= _glm.strikes.listen((s) {
        _strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _glm.stop();
    }

    if (src != _LightningSource.off) {
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
          if (mounted) setState(() {});
        }
      });
    } else {
      _strikeTimer?.cancel();
      _strikeTimer = null;
      _strikes.clear();
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

  /// Open the 3D volume view on the latest Level 2 volume for this site.
  Future<void> _open3D() async {
    setState(() => _loading = true);
    try {
      final keys = await listRecentVolumes(_site.icao, count: 1);
      if (keys.isEmpty) throw Exception('no volume for ${_site.icao}');
      final bytes = _l2Cache[keys.last] ?? await fetchVolume(keys.last);
      _l2Cache[keys.last] = bytes;
      if (!mounted) return;
      setState(() => _loading = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Volume3DScreen(
            volumeBytes: bytes,
            siteId: _site.icao,
            basemapUrl: _basemap.url,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ---------------------------------------------------------- inspector ----

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

  // ----------------------------------------------------------------- ui ----

  @override
  Widget build(BuildContext context) {
    final frame = _future && _futureFrame != null
        ? _futureFrame
        : (_frames.isEmpty ? null : _frames[_shownFrame]);
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(_site.lat, _site.lon),
              initialZoom: 7,
              minZoom: 3,
              maxZoom: 15,
              onTap: (tapPos, latlng) {
                if (_measuring) _onMeasureTap(latlng);
                if (_cursor) _aimCursor(latlng, fromTap: true);
              },
              onPointerHover: (event, latlng) {
                if (_cursor) _aimCursor(latlng);
              },
              onLongPress: (tapPos, latlng) => _inspect(latlng),
              // Pinch-zoom and drag, but no accidental two-finger rotation:
              // a twisted radar map is disorienting and hard to undo on touch.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapEvent: (_) {
                _maybeSwitchMosaic();
                _viewDebounce?.cancel();
                _viewDebounce = Timer(
                  const Duration(milliseconds: 350),
                  _renderViewport,
                );
              },
              backgroundColor: const Color(0xFF10141A),
            ),
            children: [
              TileLayer(
                urlTemplate: _basemap.url,
                userAgentPackageName: 'dev.radarapp.radar_app',
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
              if (_showOutlook)
                PolygonLayer(
                  polygons: [
                    for (final a in _outlook)
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
                    _showAlertSheet(hit.hitValues.first);
                  }
                },
                child: PolygonLayer(
                  hitNotifier: _alertHit,
                  polygons: [
                    for (final a in _alerts)
                      for (final ring in a.polygons)
                        Polygon(
                          points: ring,
                          hitValue: a,
                          color: a.color.withValues(alpha: 0.12),
                          borderColor: a.color,
                          borderStrokeWidth: 2,
                        ),
                  ],
                ),
              ),
              if (_showLightning)
                CircleLayer(
                  circles: [for (final s in _strikes) _strikeCircle(s)],
                ),
              if (_showReports)
                MarkerLayer(
                  markers: [
                    for (final r in _reports)
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
                      radius: (_cursorSample?.distanceKm ?? 0) * 1000,
                      useRadiusInMeter: true,
                      color: Colors.transparent,
                      borderColor: Colors.amberAccent.withValues(alpha: 0.85),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_cursorSite!, _cursorPos!],
                      color: Colors.amberAccent.withValues(alpha: 0.9),
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
                          color: Colors.amberAccent,
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
                      color: Colors.cyanAccent,
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
                        child: const Icon(
                          Icons.circle,
                          size: 10,
                          color: Colors.cyanAccent,
                        ),
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
              MarkerLayer(
                markers: [
                  for (final s in nexradSites)
                    if (!s.isTdwr)
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 12,
                        height: 12,
                        child: GestureDetector(
                          onTap: () => _selectSite(s, moveMap: true),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: s.icao == _site.icao
                                  ? const Color(0xFF29B6F6)
                                  : Colors.white24,
                              border: Border.all(color: Colors.black45),
                            ),
                          ),
                        ),
                      ),
                  if (_myLocation != null)
                    Marker(
                      point: _myLocation!,
                      width: 16,
                      height: 16,
                      child: const Icon(
                        Icons.my_location,
                        size: 16,
                        color: Color(0xFF64B5F6),
                      ),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    '${_basemap.attribution} · NOAA/NWS'
                    '${_lightning == _LightningSource.blitzortung || _lightning == _LightningSource.both ? ' · lightning © Blitzortung.org' : ''}',
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
          SafeArea(
            child: Column(
              children: [
                _topBar(frame),
                const Spacer(),
                if (_future)
                  Container(
                    margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xCC10141A),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.fast_forward,
                            size: 16, color: Colors.lightGreenAccent),
                        const SizedBox(width: 6),
                        Text(
                          _futureMinutes == 0
                              ? 'now'
                              : '+${_futureMinutes.round()} min',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: _futureMinutes,
                            max: 60,
                            divisions: 12,
                            onChanged: (v) =>
                                setState(() => _futureMinutes = v),
                            onChangeEnd: (_) => _renderFuture(),
                          ),
                        ),
                        const Text(
                          'forecast',
                          style:
                              TextStyle(fontSize: 10, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                if (_cursor && _cursorSample != null)
                  Builder(builder: (context) {
                    final c = _cursorSample!;
                    final value = c.rangeFolded
                        ? 'RF'
                        : c.value == null
                            ? '—'
                            : '${c.value!.toStringAsFixed(1)} ${c.unit}'.trim();
                    final kft = c.beamHeightM * 3.28084 / 1000.0;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE610141A),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.amberAccent),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_cursorPinned) ...[
                            const Icon(
                              Icons.push_pin,
                              size: 13,
                              color: Colors.amberAccent,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Text(
                            value,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.amberAccent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${c.distanceKm.toStringAsFixed(1)} km '
                            '(${(c.distanceKm * 0.621371).toStringAsFixed(1)} mi)'
                            '  ·  ${c.azimuthDeg.round()}°'
                            '  ·  ${kft.toStringAsFixed(1)} kft'
                            '  @ ${c.elevationDeg.toStringAsFixed(1)}°',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    );
                  }),
                if (_measurePts.length == 2)
                  Builder(builder: (context) {
                    final (d, b) =
                        _distanceBearing(_measurePts[0], _measurePts[1]);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE610141A),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.cyanAccent),
                      ),
                      child: Text(
                        '${d.toStringAsFixed(1)} km  '
                        '(${(d * 0.621371).toStringAsFixed(1)} mi)  ·  '
                        '${b.round()}°',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
                if (_sampleText != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE610141A),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      _sampleText!,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                _bottomBar(frame),
              ],
            ),
          ),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: 52),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topBar(_Frame? frame) {
    Duration? age;
    if (_frames.isNotEmpty) {
      age = DateTime.now().toUtc().difference(
            DateTime.fromMillisecondsSinceEpoch(
              _frames.last.meta.timestamp.toInt() * 1000,
              isUtc: true,
            ),
          );
    }
    final stale = age != null && age.inMinutes > 20;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xB310141A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            _product.isMrms ? 'CONUS' : _site.icao,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Text(
            '${_product.short}'
            '${frame != null && _product.hasTilts ? ' ${frame.meta.elevationDeg.toStringAsFixed(1)}°' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          if (_historyTime != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.indigo.shade700,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'REPLAY ${DateFormat('MMM d HH:mm').format(_historyTime!)}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          if (stale && _historyTime == null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.shade900,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${_ageLabel(age)} old',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (_error != null)
            Tooltip(
              message: _error!,
              child: const Icon(
                Icons.error_outline,
                size: 18,
                color: Colors.orangeAccent,
              ),
            ),
          PopupMenuButton<_LightningSource>(
            tooltip: 'Lightning source',
            icon: Icon(
              Icons.bolt,
              size: 20,
              color: _showLightning ? Colors.yellowAccent : Colors.white38,
            ),
            onSelected: _setLightning,
            itemBuilder: (context) => [
              for (final (src, label) in const [
                (_LightningSource.off, 'Off'),
                (_LightningSource.blitzortung, 'Blitzortung (ground network)'),
                (_LightningSource.glm, 'GOES GLM (satellite)'),
                (_LightningSource.both, 'Both'),
              ])
                CheckedPopupMenuItem(
                  value: src,
                  checked: _lightning == src,
                  child: Text(label),
                ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '3D volume view',
            onPressed: _open3D,
            icon: const Icon(
              Icons.view_in_ar,
              size: 19,
              color: Colors.white70,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Future radar (on-device forecast)',
            onPressed: () {
              setState(() {
                _future = !_future;
                if (!_future) _futureFrame = null;
              });
              if (_future) _renderFuture();
            },
            icon: Icon(
              Icons.fast_forward,
              size: 20,
              color: _future ? Colors.lightGreenAccent : Colors.white38,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Severe weather layers',
            icon: Icon(
              Icons.warning_amber,
              size: 20,
              color: (_showOutlook || _showReports)
                  ? Colors.amberAccent
                  : Colors.white70,
            ),
            onSelected: (v) {
              if (v == 'outlook') {
                setState(() => _showOutlook = !_showOutlook);
                if (_showOutlook) _loadOutlook();
              } else {
                setState(() => _showReports = !_showReports);
                if (_showReports) _loadReports();
              }
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: 'outlook',
                checked: _showOutlook,
                child: const Text('SPC convective outlook'),
              ),
              CheckedPopupMenuItem(
                value: 'reports',
                checked: _showReports,
                child: const Text("Today's storm reports"),
              ),
            ],
          ),
          PopupMenuButton<_Basemap>(
            tooltip: 'Basemap',
            icon: const Icon(Icons.layers, size: 20, color: Colors.white70),
            onSelected: (b) => setState(() => _basemap = b),
            itemBuilder: (context) => [
              for (final b in _basemaps)
                CheckedPopupMenuItem(
                  value: b,
                  checked: b == _basemap,
                  child: Text(b.label),
                ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'My location',
            onPressed: _goToMyLocation,
            icon: const Icon(
              Icons.my_location,
              size: 19,
              color: Colors.white70,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Aiming cursor — hover to read, tap to pin',
            onPressed: () {
              setState(() {
                _cursor = !_cursor;
                if (!_cursor) {
                  _cursorPos = null;
                  _cursorSample = null;
                  _cursorPinned = false;
                }
              });
              if (_cursor) _openCursorSession();
            },
            icon: Icon(
              Icons.ads_click,
              size: 20,
              color: _cursor ? Colors.amberAccent : Colors.white38,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              switch (v) {
                case 'history':
                  _pickHistory();
                case 'snapshot':
                  _saveSnapshot();
                case 'measure':
                  setState(() {
                    _measuring = !_measuring;
                    _measurePts.clear();
                  });
                case 'palette_reset':
                  _applyPalette('');
                default:
                  if (v.startsWith('pal:')) _applyPalette(v.substring(4));
              }
            },
            itemBuilder: (context) {
              final pals = () {
                try {
                  return listPalettes();
                } catch (_) {
                  return <File>[];
                }
              }();
              return [
                PopupMenuItem(
                  value: 'history',
                  child: Text(
                    _historyTime == null
                        ? 'Replay a past storm…'
                        : 'Return to live',
                  ),
                ),
                CheckedPopupMenuItem(
                  value: 'measure',
                  checked: _measuring,
                  child: const Text('Measure distance'),
                ),
                const PopupMenuItem(
                  value: 'snapshot',
                  child: Text('Save snapshot'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  enabled: false,
                  height: 28,
                  child: Text(
                    'COLOR TABLES',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
                for (final f in pals)
                  PopupMenuItem(
                    value: 'pal:${f.path}',
                    child: Text(f.uri.pathSegments.last),
                  ),
                if (pals.isEmpty)
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      'drop .pal files in\n${paletteDir().path}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'palette_reset',
                  child: Text('Built-in colors'),
                ),
              ];
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Reload',
            onPressed: _loading ? null : _loadFrames,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(_Frame? frame) {
    final ts = frame == null
        ? '—'
        : DateFormat('MMM d HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(
              frame.meta.timestamp.toInt() * 1000,
              isUtc: true,
            ).toLocal(),
          );

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xB310141A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          if (_frames.length > 1)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _playing = !_playing),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 20),
            ),
          PopupMenuButton<int>(
            tooltip: 'Animation frames',
            onSelected: (n) {
              setState(() => _frameCount = n);
              _loadFrames();
            },
            itemBuilder: (context) => [
              for (final n in const [1, 4, 8, 12])
                CheckedPopupMenuItem(
                  value: n,
                  checked: _frameCount == n,
                  child: Text(n == 1 ? 'Latest only' : '$n frames'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.burst_mode, size: 18, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    _frames.isEmpty
                        ? '$_frameCount'
                        : '${_shownFrame + 1}/${_frames.length}',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(ts, style: const TextStyle(fontSize: 12)),
          const Spacer(),
          if (_product.hasTilts) ...[
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                for (var t = 0; t < 4; t++)
                  ButtonSegment(
                    value: t,
                    label: Text('${t + 1}', style: const TextStyle(fontSize: 11)),
                  ),
              ],
              selected: {_tilt},
              onSelectionChanged: (sel) {
                setState(() {
                  _tilt = sel.first;
                  _frames = [];
                });
                _loadFrames();
              },
            ),
            const SizedBox(width: 6),
          ],
          PopupMenuButton<_Product>(
            tooltip: 'Product',
            onSelected: (p) {
              setState(() {
                _product = p;
                _frames = [];
              });
              _loadFrames();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _mrmsProduct,
                height: 36,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 44,
                      child: Text(
                        'MRMS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    Text(_mrmsProduct.label,
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(
                  'LEVEL 3',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
              for (final p in _l3Products)
                PopupMenuItem(
                  value: p,
                  height: 36,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          p.short,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Text(p.label, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(
                  'DERIVED · ON-DEVICE',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
              for (final p in _derivedProducts)
                PopupMenuItem(
                  value: p,
                  height: 36,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          p.short,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Text(p.label, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(
                  'LEVEL 2 · SUPER-RES VOLUME',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
              for (final p in _l2Products)
                PopupMenuItem(
                  value: p,
                  height: 36,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          p.short.replaceFirst('L2 ', ''),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Text(p.label, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_product.short, style: const TextStyle(fontSize: 12)),
                  const Icon(Icons.arrow_drop_up, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAlertSheet(WeatherAlert alert) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.45,
        minChildSize: 0.2,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: alert.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    alert.event,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (alert.headline.isNotEmpty)
              Text(
                alert.headline,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
            const SizedBox(height: 12),
            Text(
              alert.description,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  String _ageLabel(Duration age) {
    if (age.inHours >= 1) return '${age.inHours}h';
    return '${age.inMinutes}m';
  }
}
