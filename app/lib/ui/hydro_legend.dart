/// Discrete key for a classified field.
///
/// The colour scale down the edge of the map answers "what value is this
/// colour", which is meaningless for a classification: the numbers are class
/// ids, not a quantity. This lists the classes instead.
library;

import 'package:flutter/material.dart';

import '../data/hydrometeor.dart';

class HydroLegend extends StatelessWidget {
  final List<HydrometeorClass> classes;

  /// Class ids the filter is currently hiding. They stay listed, greyed and
  /// struck through, because the useful thing to know while dragging the
  /// filter is what you are cutting away — a class that simply vanished from
  /// the key would leave you guessing whether it was filtered out or never
  /// there.
  final Set<int> hidden;

  const HydroLegend({
    super.key,
    required this.classes,
    this.hidden = const {},
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xCC0A0D12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in classes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: hidden.contains(c.id)
                          ? c.color.withValues(alpha: 0.25)
                          : c.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    c.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: hidden.contains(c.id)
                          ? Colors.white38
                          : Colors.white,
                      decoration: hidden.contains(c.id)
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: Colors.white38,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
