/// The color key: what the colors on the map actually mean.
library;

import 'package:flutter/material.dart';

import '../src/rust/api/radar.dart';

/// A compact vertical color bar with value labels, drawn from the same table
/// the renderer used — including an imported `.pal`, so the key never
/// disagrees with the map.
class ColorKey extends StatelessWidget {
  const ColorKey({
    super.key,
    required this.scale,
    this.rangeFolded = false,
    this.barHeight = _height,
  });

  final ColorScale scale;

  /// Whether to show the range-folded swatch. Only velocity products can
  /// produce it, so it would be noise everywhere else.
  final bool rangeFolded;

  /// How tall to draw the bar. The default suits a full-window map; a small
  /// pane in a 2x2 has less room than the key wants, and a key that
  /// overflows its pane is worse than a shorter one.
  final double barHeight;

  static const double _barWidth = 14;
  static const double _height = 168;

  @override
  Widget build(BuildContext context) {
    final stops = scale.stops;
    if (stops.isEmpty) return const SizedBox.shrink();

    final lo = stops.first.value;
    final hi = stops.last.value;
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;

    // Bottom-to-top, so larger values sit higher like every other scale.
    final colors = <Color>[];
    final positions = <double>[];
    for (final s in stops.reversed) {
      colors.add(Color.fromARGB(255, s.r, s.g, s.b));
      positions.add(((hi - s.value) / span).clamp(0.0, 1.0));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xB310141A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (scale.unit.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                scale.unit,
                style: const TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: _barWidth,
                height: barHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white24),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: colors,
                    stops: positions,
                    // A stepped table must be drawn stepped, or the key
                    // implies gradations the map does not have.
                    tileMode: TileMode.clamp,
                  ),
                ),
                // Stepped tables get hard edges rather than a blend.
                child: scale.interpolate
                    ? null
                    : CustomPaint(painter: _SteppedBar(stops, lo, hi)),
              ),
              const SizedBox(width: 5),
              SizedBox(
                height: barHeight,
                child: _Ticks(
                  stops: stops,
                  lo: lo,
                  hi: hi,
                  height: barHeight,
                ),
              ),
            ],
          ),
          if (rangeFolded) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Color.fromARGB(255, scale.rfR, scale.rfG, scale.rfB),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'RF',
                  style: TextStyle(fontSize: 9, color: Colors.white70),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Paints a stepped table as flat bands, matching a non-interpolating
/// renderer instead of implying a smooth ramp.
class _SteppedBar extends CustomPainter {
  _SteppedBar(this.stops, this.lo, this.hi);

  final List<ColorScaleStop> stops;
  final double lo;
  final double hi;

  @override
  void paint(Canvas canvas, Size size) {
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    for (var i = 0; i < stops.length; i++) {
      final s = stops[i];
      final next = i + 1 < stops.length ? stops[i + 1].value : hi;
      final yTop = (hi - next) / span * size.height;
      final yBottom = (hi - s.value) / span * size.height;
      canvas.drawRect(
        Rect.fromLTRB(0, yTop, size.width, yBottom),
        Paint()..color = Color.fromARGB(255, s.r, s.g, s.b),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SteppedBar old) =>
      old.stops != stops || old.lo != lo || old.hi != hi;
}

/// Value labels down the side of the bar.
///
/// Tables have anywhere from a handful of stops to dozens, so labelling every
/// one would be unreadable. Pick a round step that yields a few labels and
/// place them by value, so they line up with the colors rather than being
/// spaced evenly.
class _Ticks extends StatelessWidget {
  const _Ticks({
    required this.stops,
    required this.lo,
    required this.hi,
    required this.height,
  });

  final List<ColorScaleStop> stops;
  final double lo;
  final double hi;
  final double height;

  @override
  Widget build(BuildContext context) {
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    final values = _tickValues(lo, hi);
    return SizedBox(
      width: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final v in values)
            Positioned(
              top: ((hi - v) / span * height - 5).clamp(0.0, height - 10),
              left: 0,
              child: Text(
                _label(v),
                style: const TextStyle(fontSize: 9, color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }

  static String _label(double v) {
    if (v.abs() >= 100) return v.round().toString();
    if (v.abs() >= 10 || v == v.roundToDouble()) return v.round().toString();
    return v.toStringAsFixed(1);
  }

  /// Round values spanning lo..hi, aiming for about five labels.
  static List<double> _tickValues(double lo, double hi) {
    final span = (hi - lo).abs();
    if (span < 1e-6) return [lo];
    const targets = [0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200];
    final rough = span / 4;
    final step = targets.firstWhere((t) => t >= rough, orElse: () => rough);

    final out = <double>[];
    var v = (lo / step).ceil() * step;
    while (v <= hi + 1e-6) {
      out.add(double.parse(v.toStringAsFixed(4)));
      v += step;
    }
    // Always anchor the ends so the range is unambiguous.
    if (out.isEmpty || (out.first - lo).abs() > step * 0.4) out.insert(0, lo);
    if ((out.last - hi).abs() > step * 0.4) out.add(hi);
    return out;
  }
}
