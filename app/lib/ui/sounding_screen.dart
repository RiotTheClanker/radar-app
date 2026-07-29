/// Upper-air sounding plot: temperature and dewpoint against pressure, with
/// the wind profile alongside.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/sounding_fetcher.dart';
import 'toolbar.dart';

class SoundingScreen extends StatefulWidget {
  const SoundingScreen({super.key, required this.site});

  /// Launch site to open on, normally the one nearest the current radar.
  final RaobSite site;

  @override
  State<SoundingScreen> createState() => _SoundingScreenState();
}

class _SoundingScreenState extends State<SoundingScreen> {
  late RaobSite _site = widget.site;
  Sounding? _sounding;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await fetchSounding(_site.id);
      if (!mounted) return;
      setState(() {
        _sounding = s;
        _loading = false;
        if (s == null) {
          _error = 'No recent sounding from ${_site.id}. '
              'Launches are usually 00Z and 12Z.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sounding;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF10141A),
        titleSpacing: 8,
        title: Text(
          '${_site.id} · ${_site.name}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          PopupMenuButton<RaobSite>(
            tooltip: 'Launch site',
            icon: const Icon(Icons.place, size: 20),
            onSelected: (site) {
              setState(() => _site = site);
              _load();
            },
            itemBuilder: (context) => [
              for (final site in raobSites)
                CheckedPopupMenuItem(
                  value: site,
                  checked: site.id == _site.id,
                  child: Text('${site.id} — ${site.name}'),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                )
              : Column(
                  children: [
                    _header(s!),
                    Expanded(child: _SoundingPlot(sounding: s)),
                  ],
                ),
    );
  }

  Widget _header(Sounding s) {
    final sfc = s.surface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      color: const Color(0xFF10141A),
      child: ToolBar(
        status: [
          Text(
            s.time == null
                ? s.title
                : '${s.time!.hour.toString().padLeft(2, '0')}Z '
                    '${s.time!.day}/${s.time!.month}',
            style: const TextStyle(fontSize: 12),
          ),
          if (sfc != null && sfc.hasTemp)
            Text(
              'sfc ${sfc.tempC!.toStringAsFixed(0)}°C'
              '${sfc.dewpointC == null ? '' : ' / ${sfc.dewpointC!.toStringAsFixed(0)}°C'}',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          Text(
            '${s.levels.length} levels',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
        actions: const [
          _Swatch(color: Color(0xFFFF5252), label: 'temp'),
          SizedBox(width: 10),
          _Swatch(color: Color(0xFF69F0AE), label: 'dewpt'),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.white70)),
      ],
    );
  }
}

/// Temperature and dewpoint traces on a log-pressure vertical axis, which is
/// how soundings are always read — equal spacing would squash everything
/// interesting into the bottom of the plot.
class _SoundingPlot extends StatelessWidget {
  const _SoundingPlot({required this.sounding});

  final Sounding sounding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return CustomPaint(
        size: Size(constraints.maxWidth, constraints.maxHeight),
        painter: _SoundingPainter(sounding),
      );
    });
  }
}

class _SoundingPainter extends CustomPainter {
  _SoundingPainter(this.sounding);

  final Sounding sounding;

  /// Plot range. Above 100 hPa there is nothing a storm-watcher needs.
  static const double _pTop = 100;
  static const double _pBottom = 1050;

  /// Width reserved on the right for wind barbs.
  static const double _windCol = 46;

  double _y(double p, double h) {
    final t = (math.log(p) - math.log(_pTop)) /
        (math.log(_pBottom) - math.log(_pTop));
    return t.clamp(0.0, 1.0) * h;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0;
    final right = size.width - _windCol;
    final plotW = right - left;
    if (plotW <= 10) return;

    final levels = sounding.levels
        .where((l) => l.pressureHpa >= _pTop && l.pressureHpa <= _pBottom)
        .toList();
    if (levels.isEmpty) return;

    // Temperature range, padded and never narrower than 40 degrees so the
    // traces do not swing wildly on a shallow sounding.
    var tMin = 999.0, tMax = -999.0;
    for (final l in levels) {
      for (final v in [l.tempC, l.dewpointC]) {
        if (v == null) continue;
        tMin = math.min(tMin, v);
        tMax = math.max(tMax, v);
      }
    }
    if (tMin > tMax) return;
    if (tMax - tMin < 40) {
      final mid = (tMin + tMax) / 2;
      tMin = mid - 20;
      tMax = mid + 20;
    }
    tMin -= 3;
    tMax += 3;
    double x(double t) => left + (t - tMin) / (tMax - tMin) * plotW;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    final label = TextPainter(textDirection: TextDirection.ltr);

    // Pressure gridlines at the levels people actually quote.
    for (final p in const [1000.0, 850.0, 700.0, 500.0, 300.0, 200.0, 100.0]) {
      final y = _y(p, size.height);
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
      label
        ..text = TextSpan(
          text: p.round().toString(),
          style: const TextStyle(fontSize: 9, color: Colors.white54),
        )
        ..layout();
      label.paint(canvas, Offset(2, y - label.height / 2));
    }

    // Isotherms every 10 degrees, with the freezing line called out since it
    // is the one that matters for hail and melting.
    for (var t = (tMin / 10).ceil() * 10; t <= tMax; t += 10) {
      final xx = x(t.toDouble());
      canvas.drawLine(
        Offset(xx, 0),
        Offset(xx, size.height),
        t == 0
            ? (Paint()
              ..color = Colors.lightBlueAccent.withValues(alpha: 0.5)
              ..strokeWidth = 1.2)
            : grid,
      );
      label
        ..text = TextSpan(
          text: '$t',
          style: TextStyle(
            fontSize: 9,
            color: t == 0 ? Colors.lightBlueAccent : Colors.white38,
          ),
        )
        ..layout();
      label.paint(canvas, Offset(xx - label.width / 2, size.height - 12));
    }

    void trace(double? Function(SoundingLevel) pick, Color color) {
      final path = Path();
      var started = false;
      for (final l in levels) {
        final v = pick(l);
        if (v == null) {
          // A gap in the data is a gap in the line, not a straight jump
          // across it.
          started = false;
          continue;
        }
        final p = Offset(x(v), _y(l.pressureHpa, size.height));
        if (started) {
          path.lineTo(p.dx, p.dy);
        } else {
          path.moveTo(p.dx, p.dy);
          started = true;
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    trace((l) => l.dewpointC, const Color(0xFF69F0AE));
    trace((l) => l.tempC, const Color(0xFFFF5252));

    // Wind down the right edge: direction as a stem, speed as a number.
    // Thinned out, because a full sounding has far more levels than fit.
    final windX = right + _windCol / 2;
    var lastY = -1e9;
    for (final l in levels) {
      if (!l.hasWind) continue;
      final y = _y(l.pressureHpa, size.height);
      if ((y - lastY).abs() < 16) continue;
      lastY = y;

      // Stem points the way the wind is going.
      final a = (l.windDirDeg! + 180) * math.pi / 180.0;
      final dx = math.sin(a) * 7;
      final dy = -math.cos(a) * 7;
      canvas.drawLine(
        Offset(windX - dx, y - dy),
        Offset(windX + dx, y + dy),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.4,
      );
      canvas.drawCircle(
        Offset(windX + dx, y + dy),
        1.8,
        Paint()..color = Colors.white70,
      );
      label
        ..text = TextSpan(
          text: l.windKt!.round().toString(),
          style: const TextStyle(fontSize: 8, color: Colors.white38),
        )
        ..layout();
      label.paint(canvas, Offset(windX + 11, y - label.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _SoundingPainter old) =>
      old.sounding != sounding;
}
