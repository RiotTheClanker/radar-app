import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/radar.dart';

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

/// Free-fly 3D storm view: WASD + Space/Shift to move, drag to look,
/// sliders to slice the volume and set the opacity floor. GPU raymarched;
/// falls back to the CPU orbit renderer when no GPU is available.
class Volume3DScreen extends StatefulWidget {
  final Uint8List volumeBytes;
  final String siteId;
  const Volume3DScreen({
    super.key,
    required this.volumeBytes,
    required this.siteId,
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

  // Clip box (fractions)
  RangeValues _clipX = const RangeValues(0, 1);
  RangeValues _clipY = const RangeValues(0, 1);
  RangeValues _clipZ = const RangeValues(0, 1);
  bool _showSlicers = false;

  // Input
  final Set<LogicalKeyboardKey> _keys = {};
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  // Frame plumbing
  ui.Image? _frame;
  bool _inFlight = false;
  bool _dirty = true;

  // Legacy (CPU orbit) fallback state
  Uint8List? _legacyPng;
  double _lyaw = 35, _lpitch = 28;
  final double _lzoom = 1.4;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _frame?.dispose();
    super.dispose();
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
      if (_px == 0 && _py == 0 && _pz == 0) {
        _px = 0;
        _py = -1.6 * _ex;
        _pz = 0.45 * _top;
      }
      setState(() => _opening = false);
      if (_gpu) {
        _ticker ??= createTicker(_onTick)..start();
        _dirty = true;
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

  // ------------------------------------------------------------- fly loop --

  void _onTick(Duration now) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (_moveCamera(dt) || _dirty) {
      _dirty = false;
      _requestFrame();
    }
  }

  bool _moveCamera(double dt) {
    if (_keys.isEmpty) return false;
    final boost =
        _keys.contains(LogicalKeyboardKey.controlLeft) ? 3.0 : 1.0;
    final speed = _ex * 0.45 * dt * boost;
    final yawR = _yaw * math.pi / 180.0;
    final fx = math.sin(yawR), fy = math.cos(yawR);
    final rx = fy, ry = -fx;
    var moved = false;
    void mv(double dx, double dy, double dz) {
      _px = (_px + dx).clamp(-2.5 * _ex, 2.5 * _ex);
      _py = (_py + dy).clamp(-2.5 * _ex, 2.5 * _ex);
      _pz = (_pz + dz).clamp(200.0, 2.2 * _top);
      moved = true;
    }

    if (_keys.contains(LogicalKeyboardKey.keyW)) mv(fx * speed, fy * speed, 0);
    if (_keys.contains(LogicalKeyboardKey.keyS)) mv(-fx * speed, -fy * speed, 0);
    if (_keys.contains(LogicalKeyboardKey.keyD)) mv(rx * speed, ry * speed, 0);
    if (_keys.contains(LogicalKeyboardKey.keyA)) mv(-rx * speed, -ry * speed, 0);
    if (_keys.contains(LogicalKeyboardKey.space) ||
        _keys.contains(LogicalKeyboardKey.keyE)) {
      mv(0, 0, speed * 0.6);
    }
    if (_keys.contains(LogicalKeyboardKey.shiftLeft) ||
        _keys.contains(LogicalKeyboardKey.keyQ)) {
      mv(0, 0, -speed * 0.6);
    }
    return moved;
  }

  Future<void> _requestFrame() async {
    if (_inFlight || !_gpu) return;
    _inFlight = true;
    try {
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
        width: 1100,
        height: 740,
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

  // ------------------------------------------------------ legacy fallback --

  Future<void> _legacyRender() async {
    try {
      final f = await renderVolume3D(
        data: widget.volumeBytes,
        yawDeg: _lyaw,
        pitchDeg: _lpitch,
        zoom: _lzoom,
        dbzMin: _threshold,
        width: 1000,
        height: 700,
      );
      if (!mounted) return;
      setState(() => _legacyPng = Uint8List.fromList(f.png));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ------------------------------------------------------------------ ui --

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF10141A),
        title: Text(
          '${widget.siteId} · 3D ${_field.label}'
          '${_gpu ? '' : ' (CPU orbit mode)'}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: 'Slice',
            onPressed: () => setState(() => _showSlicers = !_showSlicers),
            icon: Icon(
              Icons.content_cut,
              size: 19,
              color: _showSlicers ? Colors.cyanAccent : Colors.white70,
            ),
          ),
          PopupMenuButton<_VolField>(
            tooltip: 'Field',
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
      body: _opening
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _gpu ? _flyView() : _legacyView()),
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

  Widget _flyView() {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent) {
          _keys.add(e.logicalKey);
        } else if (e is KeyUpEvent) {
          _keys.remove(e.logicalKey);
        }
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onPanUpdate: (d) {
          _yaw += d.delta.dx * 0.25;
          _pitch = (_pitch - d.delta.dy * 0.22).clamp(-85.0, 85.0);
          _dirty = true;
        },
        child: Container(
          color: const Color(0xFF0A0D12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_frame != null)
                RawImage(image: _frame, fit: BoxFit.contain),
              const Positioned(
                left: 10,
                bottom: 8,
                child: Text(
                  'WASD move · Space/Shift up/down · Ctrl boost · drag look',
                  style: TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legacyView() {
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
                fit: BoxFit.contain,
              ),
      ),
    );
  }

  Widget _slicers() {
    Widget row(String label, RangeValues v, void Function(RangeValues) set) {
      return SizedBox(
        height: 30,
        child: Row(
          children: [
            SizedBox(
              width: 20,
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
        height: 40,
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
