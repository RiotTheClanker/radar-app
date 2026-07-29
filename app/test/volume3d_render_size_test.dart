import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/volume3d_screen.dart';

/// What the old fixed render cost, and what the aspect-matched one is
/// budgeted to.
const _budget = 1100 * 740;

void main() {
  test('render matches the viewport aspect instead of a fixed 3:2', () {
    // A phone in landscape: the case that used to letterbox into a window.
    final (w, h) = volumeRenderSize(const Size(2400, 1080));
    expect(w / h, closeTo(2400 / 1080, 0.02));
    expect(w, greaterThan(h));
  });

  test('a portrait viewport gets a portrait render', () {
    final (w, h) = volumeRenderSize(const Size(1080, 2400));
    expect(w / h, closeTo(1080 / 2400, 0.02));
    expect(h, greaterThan(w));
  });

  test('every shape costs about the same as the old fixed render', () {
    for (final view in const [
      Size(2400, 1080), // phone landscape
      Size(1080, 2400), // phone portrait
      Size(1100, 740), // the original shape
      Size(1920, 1080), // desktop
      Size(1280, 800), // tablet
    ]) {
      final (w, h) = volumeRenderSize(view);
      expect(
        w * h,
        closeTo(_budget, _budget * 0.02),
        reason: '$view renders ${w}x$h, which is not within budget',
      );
    }
  });

  test('a degenerate viewport falls back to the original shape', () {
    for (final view in const [Size.zero, Size(0, 500), Size(500, 0)]) {
      final (w, h) = volumeRenderSize(view);
      expect(w / h, closeTo(1100 / 740, 0.02), reason: '$view');
    }
  });

  test('extreme aspects stay within the clamp', () {
    for (final view in const [Size(4000, 100), Size(100, 4000)]) {
      final (w, h) = volumeRenderSize(view);
      expect(w, inInclusiveRange(256, 2600));
      expect(h, inInclusiveRange(256, 2600));
    }
  });
}
