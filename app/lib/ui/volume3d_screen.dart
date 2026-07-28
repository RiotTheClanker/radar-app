import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../src/rust/api/radar.dart';

/// Interactive 3D storm volume view. Drag to orbit, scroll/buttons to zoom,
/// slider to set the reflectivity floor. Rendering is CPU raymarching in the
/// Rust engine: low-res while dragging, full-res on release.
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

class _Volume3DScreenState extends State<Volume3DScreen> {
  double _yaw = 35;
  double _pitch = 28;
  double _zoom = 1.4;
  double _dbzMin = 10;

  Uint8List? _image;
  bool _rendering = false;
  bool _dirty = false;
  bool _interactive = false;

  @override
  void initState() {
    super.initState();
    _render(full: true);
  }

  Future<void> _render({required bool full}) async {
    if (_rendering) {
      _dirty = true;
      return;
    }
    _rendering = true;
    try {
      final f = await renderVolume3D(
        data: widget.volumeBytes,
        yawDeg: _yaw,
        pitchDeg: _pitch,
        zoom: _zoom,
        dbzMin: _dbzMin,
        width: full ? 1000 : 420,
        height: full ? 700 : 300,
      );
      if (!mounted) return;
      setState(() => _image = Uint8List.fromList(f.png));
    } catch (_) {
      // keep last image
    } finally {
      _rendering = false;
      if (_dirty && mounted) {
        _dirty = false;
        _render(full: !_interactive);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF10141A),
        title: Text(
          '${widget.siteId} · 3D Volume',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => _interactive = true,
              onPanUpdate: (d) {
                _yaw += d.delta.dx * 0.4;
                _pitch = (_pitch + d.delta.dy * 0.3).clamp(5.0, 85.0);
                _render(full: false);
              },
              onPanEnd: (_) {
                _interactive = false;
                _render(full: true);
              },
              child: Center(
                child: _image == null
                    ? const CircularProgressIndicator()
                    : Image.memory(
                        _image!,
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                      ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.filter_alt, size: 16, color: Colors.white54),
                  Expanded(
                    child: Slider(
                      value: _dbzMin,
                      min: 0,
                      max: 50,
                      divisions: 10,
                      label: '≥ ${_dbzMin.round()} dBZ',
                      onChanged: (v) => setState(() => _dbzMin = v),
                      onChangeEnd: (_) => _render(full: true),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () {
                      _zoom = (_zoom / 1.3).clamp(0.4, 6.0);
                      _render(full: true);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () {
                      _zoom = (_zoom * 1.3).clamp(0.4, 6.0);
                      _render(full: true);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
