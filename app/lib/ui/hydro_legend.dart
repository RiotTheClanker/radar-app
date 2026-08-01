/// Discrete key for a classified field.
///
/// The colour scale down the edge of the map answers "what value is this
/// colour", which is meaningless for a classification: the numbers are class
/// ids, not a quantity. This lists the classes instead.
///
/// In 3D the list is also the filter. Given [onToggle] each row becomes a
/// switch for its own class, which is the only control that reaches an
/// arbitrary combination — the classes have no natural order to slide a
/// threshold along, and inventing one would decide for the reader which
/// combinations are reachable.
library;

import 'package:flutter/material.dart';

import '../data/hydrometeor.dart';

class HydroLegend extends StatelessWidget {
  final List<HydrometeorClass> classes;

  /// Class ids currently switched off. They stay listed, greyed and struck
  /// through, rather than disappearing: a row that vanished would leave you
  /// unable to tell a class you filtered out from one the radar never saw,
  /// and with no way to switch it back on.
  final Set<int> hidden;

  /// Called with a class id when its row is tapped. Null leaves the key a
  /// plain legend, which is what the 2D map wants — that is the NWS's own
  /// product, and there is no palette of ours to filter there.
  final void Function(int id)? onToggle;

  /// Called when the "show all" affordance is tapped. Only offered while
  /// something is hidden, and only alongside [onToggle].
  final VoidCallback? onShowAll;

  const HydroLegend({
    super.key,
    required this.classes,
    this.hidden = const {},
    this.onToggle,
    this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    final interactive = onToggle != null;
    return Container(
      padding: EdgeInsets.fromLTRB(interactive ? 4 : 10, 6, interactive ? 6 : 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xCC0A0D12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rows that do something need to say so; a colour key is not
          // somewhere people expect to find controls.
          if (interactive)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 0, 4),
              child: hidden.isEmpty
                  ? const Text(
                      'Tap to filter',
                      style: TextStyle(fontSize: 9, color: Colors.white38),
                    )
                  : _TapTarget(
                      onTap: onShowAll,
                      child: const Text(
                        'Show all',
                        style: TextStyle(fontSize: 9, color: Colors.cyanAccent),
                      ),
                    ),
            ),
          for (final c in classes)
            _TapTarget(
              onTap: onToggle == null ? null : () => onToggle!(c.id),
              child: Padding(
                padding: EdgeInsets.fromLTRB(interactive ? 6 : 0, 1.5, 0, 1.5),
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
                        border: hidden.contains(c.id)
                            ? Border.all(color: Colors.white24)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      c.label,
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            hidden.contains(c.id) ? Colors.white38 : Colors.white,
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
            ),
        ],
      ),
    );
  }
}

/// A row that responds to a tap, or just a row when it does not. Kept as one
/// widget so the non-interactive key does not gain a hit-test region it has
/// no use for — it floats over a map that is itself draggable.
class _TapTarget extends StatelessWidget {
  final VoidCallback? onTap;
  final Widget child;
  const _TapTarget({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: child,
    );
  }
}
