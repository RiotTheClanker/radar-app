import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'data/level3_fetcher.dart';
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

/// One product on offer in the MVP UI.
class _Product {
  final String code;
  final String label;
  const _Product(this.code, this.label);
}

const _products = [
  _Product('N0B', 'Reflectivity'),
  _Product('N0G', 'Velocity'),
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
  final bool _autoSite = true;

  List<_Frame> _frames = [];
  int _frameIndex = 0;
  bool _playing = true;
  Timer? _animTimer;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadFrames();
    _startAnimation();
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    super.dispose();
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
      final keys = await listRecentKeys(
        _site.shortId,
        _product.code,
        count: 8,
      );
      if (keys.isEmpty) {
        throw Exception('no recent ${_product.code} data for ${_site.icao}');
      }
      final frames = await Future.wait(keys.map((key) async {
        final bytes = await fetchObject(key);
        final frame = await renderLevel3Frame(
          data: Uint8List.fromList(bytes),
          imageSize: 1024,
        );
        return _Frame(frame, MemoryImage(Uint8List.fromList(frame.png)));
      }));
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

  String _ageLabel(Duration age) {
    if (age.inHours >= 1) return '${age.inHours}h';
    return '${age.inMinutes}m';
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (!hasGesture || !_autoSite) return;
    final nearest = _nearestSite(camera.center);
    if (nearest.icao != _site.icao) {
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
                    '© OpenStreetMap © CARTO | NOAA/NWS data',
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
              '${frame != null ? '  ·  ${frame.meta.productName}' : ''}',
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
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final p in _products)
                ButtonSegment(value: p.code, label: Text(p.label)),
            ],
            selected: {_product.code},
            onSelectionChanged: (sel) {
              setState(() {
                _product = _products.firstWhere((p) => p.code == sel.first);
                _frames = [];
              });
              _loadFrames();
            },
          ),
        ],
      ),
    );
  }
}
