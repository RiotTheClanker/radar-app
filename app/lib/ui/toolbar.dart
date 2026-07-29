/// The map's floating top/bottom bars.
library;

import 'package:flutter/material.dart';

/// A toolbar that never runs off the edge of the screen.
///
/// [status] sits on the left, [actions] on the right. Both groups are laid out
/// as [Wrap]s, so on a wide window this is the usual single line, and as the
/// window narrows the buttons drop onto their own line (or several) rather
/// than overflowing. Portrait on a phone is the case that needs it: the map
/// toolbar's buttons alone want more width than the screen has, so a plain
/// [Row] pushes the last few off the edge.
class ToolBar extends StatelessWidget {
  const ToolBar({super.key, required this.status, required this.actions});

  /// Labels and badges describing what is on screen.
  final List<Widget> status;

  /// Buttons and menus, kept to the right when everything fits on one line.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: status,
        ),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    );
  }
}
