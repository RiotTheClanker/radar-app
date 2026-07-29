/// The on-screen flight controls for the 3D view.
///
/// Both widgets report a release when they are disposed. They can be taken
/// off screen while still held — the controls get hidden, the field is
/// switched — and in that case no pointer-up or cancel ever reaches them, so
/// without it the camera would carry on flying under the last input.
library;

import 'package:flutter/material.dart';

/// Analog movement stick: drag from the center, springs back on release.
class FlyStick extends StatefulWidget {
  final ValueChanged<Offset> onChanged;
  const FlyStick({super.key, required this.onChanged});

  @override
  State<FlyStick> createState() => FlyStickState();
}

class FlyStickState extends State<FlyStick> {
  static const double _size = 108;
  static const double _knob = 40;
  Offset _pos = Offset.zero; // pixels from center

  void _update(Offset local) {
    const c = Offset(_size / 2, _size / 2);
    var d = local - c;
    const maxR = (_size - _knob) / 2;
    if (d.distance > maxR) d = d / d.distance * maxR;
    setState(() => _pos = d);
    widget.onChanged(Offset(d.dx / maxR, d.dy / maxR));
  }

  void _release() {
    setState(() => _pos = Offset.zero);
    widget.onChanged(Offset.zero);
  }

  @override
  void dispose() {
    // The stick can be taken off screen mid-drag — controls hidden, field
    // switched — and then no pan-end or pan-cancel ever arrives. Without
    // this the camera keeps flying on the last stick value.
    widget.onChanged(Offset.zero);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(color: Colors.white24),
              ),
            ),
            Positioned(
              left: (_size - _knob) / 2 + _pos.dx,
              top: (_size - _knob) / 2 + _pos.dy,
              child: Container(
                width: _knob,
                height: _knob,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF29B6F6).withValues(alpha: 0.55),
                  border: Border.all(color: Colors.white70),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Press-and-hold button that reports its down state continuously.
class HoldButton extends StatefulWidget {
  final IconData icon;
  final ValueChanged<bool> onChanged;
  const HoldButton({super.key, required this.icon, required this.onChanged});

  @override
  State<HoldButton> createState() => HoldButtonState();
}

class HoldButtonState extends State<HoldButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    widget.onChanged(v);
  }

  @override
  void dispose() {
    // Same as the stick: disappearing while held would leave the camera
    // climbing or diving with no way to stop it.
    if (_down) widget.onChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down
              ? const Color(0xFF29B6F6).withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(widget.icon, size: 26, color: Colors.white70),
      ),
    );
  }
}
