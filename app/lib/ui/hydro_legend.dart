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
  const HydroLegend({super.key, required this.classes});

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
                      color: c.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    c.label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white,
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
