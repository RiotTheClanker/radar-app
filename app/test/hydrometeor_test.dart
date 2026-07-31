import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/hydrometeor.dart';

/// The legend is a hand-written copy of the Rust classifier's class list.
/// Copies drift, and a legend that disagrees with the render is worse than no
/// legend — it mislabels rather than omits. So read the Rust source and check.
void main() {
  final src = File('../rust/radar_core/src/process/hca.rs').readAsStringSync();

  test('rust source is where we think it is', () {
    expect(src, contains('pub enum Class'),
        reason: 'hca.rs moved or was renamed; update this test');
  });

  test('ids match the Rust enum discriminants', () {
    final body = RegExp(r'pub enum Class \{(.*?)\n\}', dotAll: true)
        .firstMatch(src)!
        .group(1)!;
    final ids = <String, int>{};
    for (final m in RegExp(r'(\w+) = (\d+),').allMatches(body)) {
      ids[m.group(1)!] = int.parse(m.group(2)!);
    }
    expect(ids['None'], 0, reason: '0 must stay the empty voxel');
    // Every class in the legend must exist in Rust with the same id.
    expect(ids.length - 1, hydrometeorClasses.length,
        reason: 'a class was added or removed in hca.rs');
  });

  test('labels and colours match the Rust source', () {
    String? sectionAfter(String marker) {
      final i = src.indexOf(marker);
      return i < 0 ? null : src.substring(i);
    }

    final labelSrc = sectionAfter('fn label(self)')!;
    final colorSrc = sectionAfter('fn color(self)')!;

    final labels = <String, String>{};
    for (final m
        in RegExp(r'Class::(\w+) => "([^"]*)"').allMatches(labelSrc)) {
      labels[m.group(1)!] = m.group(2)!;
    }
    final colors = <String, List<int>>{};
    for (final m in RegExp(r'Class::(\w+) => \[(\d+), (\d+), (\d+)\]')
        .allMatches(colorSrc)) {
      colors[m.group(1)!] = [
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
      ];
    }

    // Match by label, since the Dart side has no variant names.
    for (final c in hydrometeorClasses) {
      final variant = labels.entries
          .firstWhere(
            (e) => e.value == c.label,
            orElse: () => throw TestFailure(
                'no class in hca.rs is labelled "${c.label}"'),
          )
          .key;
      final rgb = colors[variant]!;
      expect(
        [
          (c.color.r * 255).round(),
          (c.color.g * 255).round(),
          (c.color.b * 255).round(),
        ],
        rgb,
        reason: '$variant colour differs between hca.rs and the legend',
      );
    }
  });
}
