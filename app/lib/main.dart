import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'data/alerts_fetcher.dart';
import 'data/level2_fetcher.dart';
import 'data/level3_fetcher.dart';
import 'data/lightning.dart';
import 'data/nexrad_sites.g.dart';
import 'src/rust/api/radar.dart';
import 'src/rust/frb_generated.dart';

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
  final String? tiltSuffix;
  final String? fixedCode;
  final String? l2Moment;
  const _Product(this.label, {this.tiltSuffix, this.fixedCode, this.l2Moment});

  bool get isLevel2 => l2Moment != null;
  bool get hasTilts => tiltSuffix != null || isLevel2;
  String code(int tilt) => fixedCode ?? 'N$tilt$tiltSuffix';
}

const _products = [
  _Product('Reflectivity', tiltSuffix: 'B'),
  _Product('Velocity', tiltSuffix: 'G'),
  _Product('Differential Refl (ZDR)', tiltSuffix: 'X'),
  _Product('Correlation Coeff', tiltSuffix: 'C'),
  _Product('Specific Diff Phase', tiltSuffix: 'K'),
  _Product('Hydrometeor Class', tiltSuffix: 'H'),
  _Product('Storm Total Precip', fixedCode: 'DTA'),
  _Product('L2 Reflectivity', l2Moment: 'REF'),
  _Product('L2 Velocity', l2Moment: 'VEL'),
  _Product('L2 Spectrum Width', l2Moment: 'SW'),
  _Product('L2 ZDR', l2Moment: 'ZDR'),
  _Product('L2 Correlation Coeff', l2Moment: 'RHO'),
];

class _Frame {
  final RadarFrame meta;
  final MemoryImage image;
  _Frame(this.meta, this.image);
}

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  final _mapController = MapController();

  NexradSite _site = nexradSites.firstWhere((s) => s.icao == 'KTLX');
  _Product _product = _products[0];
  int _tilt = 0;
  final bool _autoSite = true;

  List<_Frame> _frames = [];
  int _frameIndex = 0;
  bool _playing = true;
  Timer? _animTimer;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  List<WeatherAlert> _alerts = [];
  Timer? _alertTimer;
  final LayerHitNotifier<WeatherAlert> _alertHit = ValueNotifier(null);
  final Map<String, Uint8List> _l2Cache = {};

  final _blitz = BlitzortungClient();
  final List<Strike> _strikes = [];
  bool _showLightning = false;
  StreamSubscription<Strike>? _strikeSub;
  Timer? _strikeTimer;
  bool _strikesDirty = false;

  @override
  void initState() {
    super.initState();
    _loadFrames();
    _startAnimation();
    _loadAlerts();
    _alertTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _loadAlerts(),
    );
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _alertTimer?.cancel();
    _strikeTimer?.cancel();
    _strikeSub?.cancel();
    _blitz.stop();
    super.dispose();
  }

  void _toggleLightning() {
    setState(() => _showLightning = !_showLightning);
    if (_showLightning) {
      _blitz.start();
      _strikeSub ??= _blitz.strikes.listen((s) {
        _strikes.add(s);
        _strikesDirty = true;
      });
      // Repaint on a slow tick instead of per strike (tens per second).
      _strikeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
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
      _blitz.stop();
    }
  }

  Future<void> _loadAlerts() async {
    try {
      final alerts = await fetchActiveAlerts();
      if (!mounted) return;
      setState(() => _alerts = alerts);
    } catch (_) {
      // Alerts are supplementary; keep the last good set on failure.
    }
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

  int get _shownFrame => math.min(_frameIndex, _frames.length - 1);

  Future<void> _loadFrames() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final frames =
          _product.isLevel2 ? await _loadLevel2Frames() : await _loadLevel3Frames();
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
        _loading = false;
      });
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
      count: 8,
    );
    if (keys.isEmpty) {
      throw Exception('no recent $productCode data for ${_site.icao}');
    }
    return Future.wait(keys.map((key) async {
      final bytes = await fetchObject(key);
      final frame = await renderLevel3Frame(
        data: Uint8List.fromList(bytes),
        imageSize: 1024,
      );
      return _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)));
    }));
  }

  /// Level 2 volumes are big (5-15 MB), so fetch fewer frames and cache the
  /// raw bytes so tilt/moment switches don't re-download.
  Future<List<_Frame>> _loadLevel2Frames() async {
    final keys = await listRecentVolumes(_site.icao, count: 3);
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
        elevationIndex: _tilt,
        imageSize: 1024,
      );
      frames.add(_Frame(frame, MemoryImage(Uint8List.fromList(frame.png))));
    }
    // Keep the cache from growing without bound.
    while (_l2Cache.length > 6) {
      _l2Cache.remove(_l2Cache.keys.first);
    }
    return frames;
  }

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

  CircleMarker _strikeCircle(Strike s) {
    final ageMin =
        DateTime.now().toUtc().difference(s.time).inSeconds / 60.0;
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

  void _showAlertSheet(WeatherAlert alert) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
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

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (!hasGesture || !_autoSite) return;
    final nearest = _nearestSite(camera.center);
    if (nearest.icao == _site.icao) return;
    // Hysteresis: only switch once the new site is clearly closer, so panning
    // along the midline between two radars doesn't thrash back and forth.
    final dCurrent =
        _dist2(camera.center.latitude, camera.center.longitude, _site.lat, _site.lon);
    final dNearest =
        _dist2(camera.center.latitude, camera.center.longitude, nearest.lat, nearest.lon);
    if (dCurrent > dNearest * 1.3) {
      _selectSite(nearest);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frames.isEmpty ? null : _frames[_shownFrame];
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(_site.lat, _site.lon),
              initialZoom: 7,
              minZoom: 3,
              maxZoom: 14,
              onPositionChanged: _onPositionChanged,
              backgroundColor: const Color(0xFF10141A),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                userAgentPackageName: 'dev.radarapp.radar_app',
              ),
              if (frame != null)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(
                      bounds: LatLngBounds(
                        LatLng(frame.meta.north, frame.meta.west),
                        LatLng(frame.meta.south, frame.meta.east),
                      ),
                      imageProvider: frame.image,
                      gaplessPlayback: true,
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
                  circles: [
                    for (final s in _strikes) _strikeCircle(s),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final s in nexradSites)
                    if (!s.isTdwr)
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 14,
                        height: 14,
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
                ],
              ),
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Text(
                    '© OpenStreetMap © CARTO · NOAA/NWS · lightning © Blitzortung.org',
                    style: TextStyle(fontSize: 10, color: Colors.white54),
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
                _bottomBar(frame),
              ],
            ),
          ),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: 72),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topBar(_Frame? frame) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC10141A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            _site.icao,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${_site.name}, ${_site.state}'
              '${frame != null ? '  ·  ${frame.meta.productName}' : ''}'
              '${frame != null && _product.hasTilts ? '  ${frame.meta.elevationDeg.toStringAsFixed(1)}°' : ''}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          if (_error != null)
            Tooltip(
              message: _error!,
              child: const Icon(
                Icons.error_outline,
                color: Colors.orangeAccent,
              ),
            ),
          IconButton(
            tooltip: _showLightning
                ? 'Lightning on (Blitzortung.org)'
                : 'Lightning off',
            onPressed: _toggleLightning,
            icon: Icon(
              Icons.bolt,
              color: _showLightning ? Colors.yellowAccent : Colors.white38,
            ),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _loadFrames,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(_Frame? frame) {
    final ts = frame == null
        ? '—'
        : DateFormat('MMM d  HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(
              frame.meta.timestamp.toInt() * 1000,
              isUtc: true,
            ).toLocal(),
          );
    // Age of the *newest* frame — if it's old, the radar is likely down.
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
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC10141A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _playing = !_playing),
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          Text(ts, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 4),
          Text(
            _frames.isEmpty ? '' : '${_shownFrame + 1}/${_frames.length}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          if (stale) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.orange.shade900,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'RADAR DOWN? ${_ageLabel(age)} old',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (_product.hasTilts) ...[
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (var t = 0; t < 4; t++)
                  ButtonSegment(value: t, label: Text('${t + 1}')),
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
            const SizedBox(width: 8),
          ],
          PopupMenuButton<_Product>(
            tooltip: 'Product',
            initialValue: _product,
            onSelected: (p) {
              setState(() {
                _product = p;
                _frames = [];
              });
              _loadFrames();
            },
            itemBuilder: (context) => [
              for (final p in _products)
                PopupMenuItem(value: p, child: Text(p.label)),
            ],
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _product.label,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Icon(Icons.arrow_drop_up, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
