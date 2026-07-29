import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/basemap_tiles.dart';
import '../data/terrain_tiles.dart';
import '../data/user_files.dart';
import '../src/rust/api/radar.dart';
import 'fly_controls.dart';
import 'toolbar.dart';

/// Pixels the raymarcher may fill in one frame. This is what the old fixed
/// 1100x740 render cost, so reshaping a frame to the screen is no more work.
const double _pixelBudget = 1100 * 740;

/// Render dimensions for a viewport of [view]: its aspect ratio at
/// [_pixelBudget], rather than a fixed shape.
///
/// The raymarcher used to render a constant 1100x740 (3:2) that was then
/// letterboxed to fit, which on a phone in landscape — nearer 2:1 — left the
/// storm in a window with black bars either side. Rendering at the viewport's
/// own aspect fills the screen for the same number of pixels.
@visibleForTesting
(int, int) volumeRenderSize(Size view) {
  final aspect = (view.width <= 0 || view.height <= 0)
      ? 1100 / 740
      : view.width / view.height;
  final h = math.sqrt(_pixelBudget / aspect);
  return (
    (h * aspect).round().clamp(256, 2600),
    h.round().clamp(256, 2600),
  );
}

/// Keys the fly camera consumes. Everything else is left alone so the rest
/// of the app's shortcuts still work.
final _flyKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyS,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.controlLeft,
};

/// Fields available as 3D volumes.
class _VolField {
  final String moment;
  final String label;
  const _VolField(this.moment, this.label);
}

const _volFields = [
  _VolField('REF', 'Reflectivity'),
  _VolField('SRM', 'Wind (storm-rel)'),
  _VolField('VEL', 'Wind (ground-rel)'),
  _VolField('ZDR', 'ZDR'),
  _VolField('RHO', 'Corr Coeff'),
];

/// Free-fly 3D storm view.
///
/// Touch: one finger looks, two fingers pan, pinch flies forward/back, and
/// the on-screen stick drives movement. Desktop: WASD + Space/Shift, drag to
/// look, scroll wheel to dolly. GPU raymarched, with a CPU orbit fallback.
class Volume3DScreen extends StatefulWidget {
  final Uint8List volumeBytes;
  final String siteId;

  /// Tile URL of the basemap the user had on the map, draped on the ground.
  final String basemapUrl;
  const Volume3DScreen({
    super.key,
    required this.volumeBytes,
    required this.siteId,
    required this.basemapUrl,
  });

  @override
  State<Volume3DScreen> createState() => _Volume3DScreenState();
}

class _Volume3DScreenState extends State<Volume3DScreen>
    with SingleTickerProviderStateMixin {
  _VolField _field = _volFields[0];
  double _threshold = 10;

  // Session
  bool _opening = true;
  bool _gpu = false;
  double _ex = 120000;
  double _top = 64000;
  String? _error;

  // Camera
  double _px = 0, _py = 0, _pz = 0;
  double _yaw = 0, _pitch = -6;

  // Clip box (fractions of the volume)
  RangeValues _clipX = const RangeValues(0, 1);
  RangeValues _clipY = const RangeValues(0, 1);
  RangeValues _clipZ = const RangeValues(0, 1);
  bool _showSlicers = false;

  // Continuous inputs
  final Set<LogicalKeyboardKey> _keys = {};
  Offset _stick = Offset.zero; // on-screen movement stick, -1..1
  double _vertInput = 0; // on-screen up/down buttons
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  // Gesture state
  double _lastScale = 1;

  // Ground basemap (stitched once, re-applied when the session is rebuilt)
  StitchedMap? _ground;
  bool _groundLoading = false;

  /// Whether to shade the cone of silence, the unsampled column standing over
  /// the radar. Off by default; it is an overlay on top of the data.
  bool _showCone = false;

  /// Terrain relief. Off by default: it is a second set of tiles to fetch and
  /// it is not always wanted, so it is opt-in per the request.
  bool _terrain = false;
  TerrainGrid? _terrainGrid;
  bool _terrainLoading = false;

  // Frame plumbing
  ui.Image? _frame;
  bool _inFlight = false;
  bool _dirty = true;

  // Legacy (CPU orbit) fallback state
  Uint8List? _legacyPng;
  double _lyaw = 35, _lpitch = 28;
  final double _lzoom = 1.4;

  /// Size of the area the frame is displayed in. The raymarcher renders to
  /// this shape so the result fills the screen rather than being letterboxed.
  Size _viewSize = const Size(1100, 740);
  int _renderW = 1100;
  int _renderH = 740;

  /// Whether the on-screen controls are showing. Hiding them leaves nothing
  /// but the storm and a single button to bring them back.
  bool _chrome = true;

  /// Watches for the app leaving the foreground, which can swallow the
  /// release half of whatever is being held.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // The storm is the whole point of this screen, so take the full display
    // and let the system bars come back on a swipe.
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _clearInputs();
      },
    );
    _open();
  }

  /// Forget every held input. Anything still down when the app is backgrounded
  /// or the screen is torn down would otherwise keep driving the camera.
  void _clearInputs() {
    _keys.clear();
    _stick = Offset.zero;
    _vertInput = 0;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clearInputs();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
    _ticker?.dispose();
    _frame?.dispose();
    super.dispose();
  }

  /// Records a new viewport size and asks for a frame that matches it.
  void _noteViewSize(Size size, {required bool legacy}) {
    if (size == _viewSize || size.isEmpty) return;
    _viewSize = size;
    // Called from build, so defer the re-render until the frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (legacy) {
        _legacyRender();
      } else {
        _dirty = true;
      }
    });
  }

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final info = await volume3DOpen(
        data: widget.volumeBytes,
        moment: _field.moment,
        threshold: _threshold,
      );
      if (!mounted) return;
      _gpu = info.gpu;
      _ex = info.halfExtentM;
      _top = info.topM;
      if (_px == 0 && _py == 0 && _pz == 0) _resetCamera();
      setState(() => _opening = false);
      if (_gpu) {
        _ticker ??= createTicker(_onTick)..start();
        _dirty = true;
        unawaited(_applyGround());
      } else {
        await _legacyRender();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = e.toString();
      });
    }
  }

  void _resetCamera() {
    _px = 0;
    _py = -1.6 * _ex;
    _pz = 0.45 * _top;
    _yaw = 0;
    _pitch = -6;
    _dirty = true;
  }

  /// Fetch (once) and upload the basemap that goes under the storm.
  Future<void> _applyGround() async {
    if (_groundLoading) return;
    _groundLoading = true;
    try {
      if (_ground == null) {
        final b = await volume3DGroundBounds();
        if (b.length < 4) return;
        _ground = await stitchBasemap(
          urlTemplate: widget.basemapUrl,
          north: b[0],
          south: b[1],
          east: b[2],
          west: b[3],
        );
      }
      final g = _ground;
      if (g == null || !mounted) return;
      await volume3DSetGround(
        rgba: g.rgba,
        width: g.width,
        height: g.height,
      );
      _dirty = true;
      if (_terrain) unawaited(_applyTerrain());
    } catch (_) {
      // The storm renders fine without a basemap.
    } finally {
      _groundLoading = false;
    }
  }

  /// Fetch (once) and upload the heightfield under the storm.
  Future<void> _applyTerrain() async {
    if (_terrainLoading) return;
    _terrainLoading = true;
    try {
      if (_terrainGrid == null) {
        final b = await volume3DGroundBounds();
        if (b.length < 4) return;
        _terrainGrid = await fetchTerrain(
          north: b[0],
          south: b[1],
          east: b[2],
          west: b[3],
        );
      }
      final t = _terrainGrid;
      if (t == null || !mounted || !_terrain) return;
      await volume3DSetTerrain(
        heights: t.heights,
        width: t.width,
        height: t.height,
      );
      _dirty = true;
      if (mounted) setState(() {});
    } catch (_) {
      // The storm renders fine on a flat ground plane.
    } finally {
      _terrainLoading = false;
    }
  }

  /// Show or hide the cone of silence.
  Future<void> _toggleCone() async {
    setState(() => _showCone = !_showCone);
    try {
      await volume3DShowCone(show_: _showCone);
      _dirty = true;
    } catch (_) {
      // Nothing to draw if the session has gone.
    }
  }

  /// Turn relief on or off. Off sends an empty heightfield, which puts the
  /// flat plane back without tearing down the session.
  Future<void> _toggleTerrain() async {
    setState(() => _terrain = !_terrain);
    if (_terrain) {
      await _applyTerrain();
    } else {
      try {
        await volume3DSetTerrain(heights: Float32List(0), width: 0, height: 0);
        _dirty = true;
      } catch (_) {
        // Nothing to undo if the session has gone.
      }
    }
  }

  // ------------------------------------------------------------- fly loop --

  void _onTick(Duration now) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : ((now - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = now;
    if (_moveCamera(dt) || _dirty) {
      _dirty = false;
      _requestFrame();
    }
  }

  /// Unit vector the camera is looking along.
  List<double> get _forward {
    final y = _yaw * math.pi / 180.0;
    final p = _pitch * math.pi / 180.0;
    return [math.cos(p) * math.sin(y), math.cos(p) * math.cos(y), math.sin(p)];
  }

  /// Horizontal unit vector to the camera's right.
  List<double> get _right {
    final y = _yaw * math.pi / 180.0;
    return [math.cos(y), -math.sin(y)];
  }

  void _translate(double dx, double dy, double dz) {
    _px = (_px + dx).clamp(-2.5 * _ex, 2.5 * _ex);
    _py = (_py + dy).clamp(-2.5 * _ex, 2.5 * _ex);
    _pz = (_pz + dz).clamp(200.0, 2.2 * _top);
  }

  bool _moveCamera(double dt) {
    var fwdIn = -_stick.dy; // stick up = forward
    var strafeIn = _stick.dx;
    var vertIn = _vertInput;

    if (_keys.contains(LogicalKeyboardKey.keyW)) fwdIn += 1;
    if (_keys.contains(LogicalKeyboardKey.keyS)) fwdIn -= 1;
    if (_keys.contains(LogicalKeyboardKey.keyD)) strafeIn += 1;
    if (_keys.contains(LogicalKeyboardKey.keyA)) strafeIn -= 1;
    if (_keys.contains(LogicalKeyboardKey.space) ||
        _keys.contains(LogicalKeyboardKey.keyE)) {
      vertIn += 1;
    }
    if (_keys.contains(LogicalKeyboardKey.shiftLeft) ||
        _keys.contains(LogicalKeyboardKey.keyQ)) {
      vertIn -= 1;
    }
    if (fwdIn == 0 && strafeIn == 0 && vertIn == 0) return false;

    final boost = _keys.contains(LogicalKeyboardKey.controlLeft) ? 3.0 : 1.0;
    final speed = _ex * 0.45 * dt * boost;
    final f = _forward;
    final r = _right;
    _translate(
      f[0] * fwdIn * speed + r[0] * strafeIn * speed,
      f[1] * fwdIn * speed + r[1] * strafeIn * speed,
      f[2] * fwdIn * speed + vertIn * speed * 0.6,
    );
    return true;
  }

  Future<void> _requestFrame() async {
    if (_inFlight || !_gpu) return;
    _inFlight = true;
    try {
      final (rw, rh) = volumeRenderSize(_viewSize);
      _renderW = rw;
      _renderH = rh;
      final f = await volume3DRenderFly(
        eyeX: _px,
        eyeY: _py,
        eyeZ: _pz,
        yawDeg: _yaw,
        pitchDeg: _pitch,
        clip: [
          _clipX.start,
          _clipY.start,
          _clipZ.start,
          _clipX.end,
          _clipY.end,
          _clipZ.end,
        ],
        width: rw,
        height: rh,
      );
      final img = await _toImage(f);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _frame?.dispose();
        _frame = img;
      });
    } catch (e) {
      _error ??= e.toString();
    } finally {
      _inFlight = false;
    }
  }

  Future<ui.Image> _toImage(RawFrame f) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(f.rgba),
      f.width.toInt(),
      f.height.toInt(),
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  // ------------------------------------------------------------- gestures --

  void _onScaleStart(ScaleStartDetails d) => _lastScale = 1;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final delta = d.focalPointDelta;
    if (d.pointerCount >= 2) {
      // Two fingers: pinch flies along the view axis, drag pans the camera.
      final ds = d.scale / (_lastScale == 0 ? 1 : _lastScale);
      _lastScale = d.scale;
      final f = _forward;
      final dolly = (ds - 1.0) * _ex * 1.6;
      _translate(f[0] * dolly, f[1] * dolly, f[2] * dolly);

      final r = _right;
      final pan = _ex * 0.0016;
      _translate(
        -r[0] * delta.dx * pan,
        -r[1] * delta.dx * pan,
        delta.dy * pan * 0.7,
      );
    } else {
      // One finger / mouse drag: look around.
      _yaw += delta.dx * 0.25;
      _pitch = (_pitch - delta.dy * 0.22).clamp(-85.0, 85.0);
    }
    _dirty = true;
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final f = _forward;
    final d = -e.scrollDelta.dy * _ex * 0.0012;
    _translate(f[0] * d, f[1] * d, f[2] * d);
    _dirty = true;
  }

  // ------------------------------------------------------ legacy fallback --

  Future<void> _legacyRender() async {
    try {
      final (rw, rh) = volumeRenderSize(_viewSize);
      final f = await renderVolume3D(
        data: widget.volumeBytes,
        yawDeg: _lyaw,
        pitchDeg: _lpitch,
        zoom: _lzoom,
        dbzMin: _threshold,
        width: rw,
        height: rh,
      );
      if (!mounted) return;
      setState(() => _legacyPng = Uint8List.fromList(f.png));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Project a world point into widget coordinates, or null when it is
  /// behind the camera or outside the rendered frame.
  Offset? _project(List<double> p, Size size) {
    final imgW = _renderW.toDouble(), imgH = _renderH.toDouble();
    final yaw = _yaw * math.pi / 180.0;
    final pitch = _pitch * math.pi / 180.0;
    final f = [
      math.cos(pitch) * math.sin(yaw),
      math.cos(pitch) * math.cos(yaw),
      math.sin(pitch),
    ];
    final r = [math.cos(yaw), -math.sin(yaw), 0.0];
    final u = [
      -math.sin(yaw) * math.sin(pitch),
      -math.cos(yaw) * math.sin(pitch),
      math.cos(pitch),
    ];
    final d = [p[0] - _px, p[1] - _py, p[2] - _pz];
    final c = d[0] * f[0] + d[1] * f[1] + d[2] * f[2];
    if (c <= 1) return null;
    final a = d[0] * r[0] + d[1] * r[1] + d[2] * r[2];
    final b = d[0] * u[0] + d[1] * u[1] + d[2] * u[2];
    const fov = 55.0 * math.pi / 180.0;
    final planeH = 2 * math.tan(fov / 2);
    final planeW = planeH * imgW / imgH;
    final ix = ((a / c) / planeW + 0.5) * imgW;
    final iy = (0.5 - (b / c) / planeH) * imgH;
    if (ix < 0 || ix > imgW || iy < 0 || iy > imgH) return null;
    // Mirrors the BoxFit.cover the frame is drawn with.
    final scale = math.max(size.width / imgW, size.height / imgH);
    return Offset(
      (size.width - imgW * scale) / 2 + ix * scale,
      (size.height - imgH * scale) / 2 + iy * scale,
    );
  }

  /// Save what's on screen to ~/Pictures/taa-yuku-radar.
  Future<void> _saveSnapshot() async {
    try {
      Uint8List? png;
      if (_gpu && _frame != null) {
        final data =
            await _frame!.toByteData(format: ui.ImageByteFormat.png);
        png = data?.buffer.asUint8List();
      } else {
        png = _legacyPng;
      }
      if (png == null) return;
      final f = saveSnapshot(png, '${widget.siteId}_3D_${_field.moment}');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Saved ${f.path}')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ------------------------------------------------------------------ ui --

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    // No AppBar: the render runs edge to edge and the controls float on top,
    // so landscape gets the whole display instead of a letterboxed strip.
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D12),
      body: _opening
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                _gpu ? _flyView() : _legacyView(),
                if (_chrome) ...[
                  Positioned(left: 0, right: 0, top: 0, child: _topOverlay()),
                  Positioned(left: 0, right: 0, bottom: 0, child: _bottomOverlay()),
                ] else
                  Positioned(
                    right: 8,
                    top: topInset + 8,
                    child: _iconBlob(
                      icon: Icons.visibility,
                      tooltip: 'Show controls',
                      onPressed: () => setState(() => _chrome = true),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Translucent bar over the top of the render, replacing the AppBar.
  ///
  /// The compass and the gesture hint live inside it rather than floating at
  /// a fixed offset, so they still clear the buttons when the bar wraps onto
  /// a second line on a narrow screen.
  Widget _topOverlay() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC0A0D12), Color(0x000A0D12)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 4, 0),
              child: ToolBar(
                status: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, size: 20),
                  ),
                  Text(
                    '${widget.siteId} · ${_field.label}'
                    '${_gpu ? '' : ' (CPU orbit)'}',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
                actions: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Hide controls',
                    onPressed: () => setState(() => _chrome = false),
                    icon: const Icon(Icons.visibility_off, size: 19),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Save snapshot',
                    onPressed: _saveSnapshot,
                    icon: const Icon(Icons.photo_camera, size: 19),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Reset view',
                    onPressed: () {
                      _resetCamera();
                      if (_gpu) {
                        setState(() {});
                      } else {
                        _legacyRender();
                      }
                    },
                    icon: const Icon(Icons.center_focus_strong, size: 20),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Cone of silence',
                    onPressed: _toggleCone,
                    icon: Icon(
                      Icons.signal_cellular_alt,
                      size: 19,
                      color: _showCone ? Colors.cyanAccent : Colors.white70,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Terrain',
                    onPressed: _toggleTerrain,
                    icon: Icon(
                      Icons.terrain,
                      size: 19,
                      color: _terrain ? Colors.lightGreenAccent : Colors.white70,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Slice',
                    onPressed: () =>
                        setState(() => _showSlicers = !_showSlicers),
                    icon: Icon(
                      Icons.content_cut,
                      size: 19,
                      color: _showSlicers ? Colors.cyanAccent : Colors.white70,
                    ),
                  ),
                  PopupMenuButton<_VolField>(
                    tooltip: 'Field',
                    icon: const Icon(Icons.layers, size: 20),
                    onSelected: (f) {
                      setState(() => _field = f);
                      _open();
                    },
                    itemBuilder: (context) => [
                      for (final f in _volFields)
                        CheckedPopupMenuItem(
                          value: f,
                          checked: f.moment == _field.moment,
                          child: Text(f.label),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_gpu)
                    const Expanded(
                      child: IgnorePointer(
                        child: Text(
                          'drag look · 2-finger pan · pinch fly '
                          '· stick move',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  IgnorePointer(child: _Compass(yaw: _yaw, pitch: _pitch)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Flight stick, altitude pad, slice sliders and the threshold slider, all
  /// stacked bottom-up so they can never land on top of one another.
  Widget _bottomOverlay() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC0A0D12), Color(0x000A0D12)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_gpu)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FlyStick(onChanged: (v) => _stick = v),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HoldButton(
                        icon: Icons.keyboard_arrow_up,
                        onChanged: (down) => _vertInput = down ? 1 : 0,
                      ),
                      const SizedBox(height: 10),
                      HoldButton(
                        icon: Icons.keyboard_arrow_down,
                        onChanged: (down) => _vertInput = down ? -1 : 0,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 11,
                ),
              ),
            ),
          if (_showSlicers) _slicers(),
          _bottomControls(),
        ],
      ),
    );
  }

  /// Round translucent button used for the lone "show controls" affordance.
  Widget _iconBlob({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: Colors.white70),
      ),
    );
  }

  Widget _flyView() {
    return Focus(
      autofocus: true,
      // A key held while focus moves elsewhere — a toolbar button, the field
      // menu, another window — never delivers its key-up, and the camera
      // would fly on by itself. Drop everything held on the way out.
      onFocusChange: (hasFocus) {
        if (!hasFocus) _keys.clear();
      },
      onKeyEvent: (node, e) {
        if (!_flyKeys.contains(e.logicalKey)) return KeyEventResult.ignored;
        if (e is KeyDownEvent) {
          _keys.add(e.logicalKey);
        } else if (e is KeyUpEvent) {
          _keys.remove(e.logicalKey);
        }
        return KeyEventResult.handled;
      },
      child: Listener(
        onPointerSignal: _onScroll,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          _noteViewSize(size, legacy: false);
          final radarPin = _project(const [0.0, 0.0, 0.0], size);
          return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              child: Container(
                color: const Color(0xFF0A0D12),
                child: _frame == null
                    ? const Center(child: CircularProgressIndicator())
                    : RawImage(image: _frame, fit: BoxFit.cover),
              ),
            ),
            // Radar site marker, projected with the render camera.
            if (radarPin != null)
              Positioned(
                left: radarPin.dx - 11,
                top: radarPin.dy - 30,
                child: IgnorePointer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_on,
                        size: 22,
                        color: Colors.cyanAccent.withValues(alpha: 0.95),
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black),
                        ],
                      ),
                      Text(
                        widget.siteId,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.cyanAccent,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          );
        }),
      ),
    );
  }

  Widget _legacyView() {
    return LayoutBuilder(builder: (context, constraints) {
      _noteViewSize(
        Size(constraints.maxWidth, constraints.maxHeight),
        legacy: true,
      );
      return GestureDetector(
        onPanUpdate: (d) {
          _lyaw += d.delta.dx * 0.4;
          _lpitch = (_lpitch + d.delta.dy * 0.3).clamp(5.0, 85.0);
        },
        onPanEnd: (_) => _legacyRender(),
        child: Center(
          child: _legacyPng == null
              ? const CircularProgressIndicator()
              : Image.memory(
                  _legacyPng!,
                  gaplessPlayback: true,
                  fit: BoxFit.cover,
                ),
        ),
      );
    });
  }

  Widget _slicers() {
    Widget row(String label, RangeValues v, void Function(RangeValues) set) {
      return SizedBox(
        height: 32,
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                label,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
            Expanded(
              child: RangeSlider(
                values: v,
                onChanged: (nv) {
                  set(nv);
                  setState(() => _dirty = true);
                  if (!_gpu) _legacyRender();
                },
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          row('W-E', _clipX, (v) => _clipX = v),
          row('S-N', _clipY, (v) => _clipY = v),
          row('Z', _clipZ, (v) => _clipZ = v),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.filter_alt, size: 16, color: Colors.white54),
            Expanded(
              child: Slider(
                value: _threshold,
                min: 0,
                max: 50,
                divisions: 25,
                label: _field.moment == 'REF'
                    ? '≥ ${_threshold.round()} dBZ'
                    : 'floor ${_threshold.round()}',
                onChanged: (v) => setState(() => _threshold = v),
                onChangeEnd: (v) async {
                  if (_gpu) {
                    await volume3DSetThreshold(threshold: v);
                    _dirty = true;
                  } else {
                    _legacyRender();
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// Heading rose: the needle points north, and the readout shows the
/// camera's compass bearing and pitch.
class _Compass extends StatelessWidget {
  final double yaw;
  final double pitch;
  const _Compass({required this.yaw, required this.pitch});

  @override
  Widget build(BuildContext context) {
    final heading = ((yaw % 360) + 360) % 360;
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final label = dirs[(((heading + 22.5) % 360) ~/ 45)];
    return Column(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.45),
            border: Border.all(color: Colors.white24),
          ),
          child: Transform.rotate(
            angle: -heading * math.pi / 180.0,
            child: CustomPaint(painter: _CompassPainter()),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '$label ${heading.round()}°  ${pitch >= 0 ? '+' : ''}${pitch.round()}°',
          style: const TextStyle(fontSize: 10, color: Colors.white70),
        ),
      ],
    );
  }
}

class _CompassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;
    final north = Paint()..color = const Color(0xFFFF5252);
    final south = Paint()..color = Colors.white70;
    // North half of the needle
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx - 5, c.dy + 3)
        ..lineTo(c.dx + 5, c.dy + 3)
        ..close(),
      north,
    );
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy + r)
        ..lineTo(c.dx - 4, c.dy + 2)
        ..lineTo(c.dx + 4, c.dy + 2)
        ..close(),
      south,
    );
    final tp = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(fontSize: 9, color: Color(0xFFFF8A80)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, 0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
