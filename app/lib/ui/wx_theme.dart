/// The flat, dense chrome the workspace is built out of.
///
/// The old UI floated rounded translucent cards over the map. That reads as a
/// phone app: it spends screen space on padding and corner radius, and every
/// control is one popup menu deep. A radar workstation wants the opposite —
/// thin solid strips docked to the edges, square corners, small type, and the
/// products you switch between constantly sitting on screen as one click.
///
/// Everything here is deliberately plain: no ripples, no shadows, no
/// elevation. Buttons are [GestureDetector]s with a hover tint rather than
/// [InkWell]s, both because the ink splash is the single most "Material"
/// thing on screen and because it frees these widgets from needing a
/// [Material] ancestor.
library;

import 'package:flutter/material.dart';

/// The workspace palette. One family, dark-blue-black through slate, so the
/// chrome recedes and the radar image is the only saturated thing on screen.
abstract final class Wx {
  /// Map background, and the void behind the panes.
  static const bg0 = Color(0xFF0D1014);

  /// Chrome strips: menu bar, product bar, status bar.
  static const bg1 = Color(0xFF191D23);

  /// Raised controls sitting on a strip, and menu surfaces.
  static const bg2 = Color(0xFF232830);

  /// Hover.
  static const bg3 = Color(0xFF2E343E);

  /// Hairlines between strips and between panes.
  static const line = Color(0xFF333A44);

  /// The focused pane's border.
  static const lineBright = Color(0xFF4A5462);

  static const text = Color(0xFFC8CDD4);
  static const textDim = Color(0xFF7C848F);
  static const textFaint = Color(0xFF565D67);

  /// Selection and "this is on".
  static const accent = Color(0xFF3FA7E0);
  static const accentFill = Color(0x333FA7E0);

  static const warn = Color(0xFFE0A03F);
  static const danger = Color(0xFFE05B4A);
  static const good = Color(0xFF6FBF73);

  /// Chrome strip heights. Tight on purpose — every pixel here is a pixel
  /// not showing weather.
  static const barH = 30.0;
  static const statusH = 24.0;

  static const label = TextStyle(
    fontSize: 11.5,
    height: 1.1,
    color: text,
    letterSpacing: 0.2,
  );

  static const labelDim = TextStyle(
    fontSize: 11.5,
    height: 1.1,
    color: textDim,
    letterSpacing: 0.2,
  );

  /// Numbers that update in place — timestamps, ranges, readouts. Tabular so
  /// they stop jittering as the digits change.
  static const mono = TextStyle(
    fontSize: 11.5,
    height: 1.1,
    color: text,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Section headings inside menus.
  static const heading = TextStyle(
    fontSize: 10,
    height: 1.1,
    color: textFaint,
    letterSpacing: 0.9,
    fontWeight: FontWeight.w600,
  );
}

ThemeData wxTheme() {
  const scheme = ColorScheme.dark(
    primary: Wx.accent,
    secondary: Wx.accent,
    surface: Wx.bg1,
    onSurface: Wx.text,
    error: Wx.danger,
  );
  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Wx.bg0,
    canvasColor: Wx.bg1,
    dividerColor: Wx.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: const TextTheme(
      bodyMedium: Wx.label,
      bodySmall: Wx.labelDim,
      labelLarge: Wx.label,
    ),
    iconTheme: const IconThemeData(size: 16, color: Wx.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: const TextStyle(fontSize: 11, color: Wx.text),
      decoration: BoxDecoration(
        color: Wx.bg2,
        border: Border.all(color: Wx.line),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Wx.bg2,
      elevation: 0,
      textStyle: Wx.label,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Wx.line),
        borderRadius: BorderRadius.zero,
      ),
    ),
    // The sheets that survive from the old UI (alert detail, storm cells)
    // get square corners so they match the rest.
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Wx.bg1,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Wx.line),
        borderRadius: BorderRadius.zero,
      ),
    ),
    // Not const: [SliderComponentShape.noOverlay] is a static final, not a
    // constant. The overlay is the pressed-state halo, which is the one
    // remaining bit of Material bloom on an otherwise flat control.
    sliderTheme: SliderThemeData(
      trackHeight: 2,
      activeTrackColor: Wx.accent,
      inactiveTrackColor: Wx.line,
      thumbColor: Wx.accent,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Wx.accent,
      linearTrackColor: Colors.transparent,
    ),
  );
}

/// A docked chrome strip. [top]/[bottom] pick which edge gets the hairline,
/// so stacked bars never draw a double-thickness rule between them.
///
/// [leading] scrolls horizontally when it does not fit; [trailing] is pinned
/// to the right and always visible. The scroll is what makes these bars
/// survive a phone in portrait, where the buttons alone are wider than the
/// screen — the previous toolbar wrapped onto extra lines for the same
/// reason, which a fixed-height strip cannot do.
class WxBar extends StatelessWidget {
  const WxBar({
    super.key,
    required this.leading,
    this.trailing = const [],
    this.height = Wx.barH,
    this.top = false,
    this.bottom = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  final List<Widget> leading;
  final List<Widget> trailing;
  final double height;
  final bool top;
  final bool bottom;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: Wx.bg1,
        border: Border(
          top: top ? const BorderSide(color: Wx.line) : BorderSide.none,
          bottom: bottom ? const BorderSide(color: Wx.line) : BorderSide.none,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            // Fades the last few pixels so a bar that has more to show reads
            // as scrollable rather than broken — a label chopped mid-word at
            // a hard edge looks like a layout bug. Sized in pixels rather
            // than a fraction so a wide bar, where the fade falls on empty
            // background, is left alone.
            child: ShaderMask(
              shaderCallback: (rect) {
                final fade = (14 / rect.width).clamp(0.0, 0.4);
                return LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: const [Colors.black, Colors.black, Colors.transparent],
                  stops: [0, 1 - fade, 1],
                ).createShader(rect);
              },
              blendMode: BlendMode.dstIn,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                // Dragging a toolbar is not a gesture anyone reaches for, but
                // it must not eat the trackpad/wheel scroll either — this
                // only moves when the content genuinely overflows.
                child: Row(children: leading),
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// 1px vertical rule for grouping controls inside a [WxBar].
class WxSep extends StatelessWidget {
  const WxSep({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        color: Wx.line,
      );
}

/// A flat square button. Set [active] for a control that is currently on —
/// it fills with the accent and grows an accent underline, which is legible
/// at a glance across four panes' worth of chrome.
class WxButton extends StatefulWidget {
  const WxButton({
    super.key,
    this.label,
    this.icon,
    this.onTap,
    this.active = false,
    this.tooltip,
    this.color,
    this.minWidth = 0,
    this.dense = false,
    this.height = Wx.barH,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;

  /// Overrides the foreground colour — for state that means something beyond
  /// on/off, like a stale-data warning.
  final Color? color;
  final double minWidth;
  final bool dense;

  /// Matched to the bar the button sits in, so the active underline lands on
  /// the strip's bottom edge instead of floating inside it.
  final double height;

  @override
  State<WxButton> createState() => _WxButtonState();
}

class _WxButtonState extends State<WxButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    // Disabled dims, it does not overrule. A control that is switched on but
    // momentarily unavailable — the loop still armed while a single-frame
    // product is up — has to keep reading as on, or the only way to find out
    // is to enable it again and watch what happens.
    final base = widget.color ?? (widget.active ? Wx.accent : Wx.text);
    final fg = enabled
        ? base
        : (widget.active ? base.withValues(alpha: 0.45) : Wx.textFaint);
    final pad = widget.dense ? 5.0 : 8.0;

    Widget content = Container(
      height: widget.height,
      constraints: BoxConstraints(minWidth: widget.minWidth),
      padding: EdgeInsets.symmetric(horizontal: pad),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.active
            ? Wx.accentFill
            : (_hover && enabled ? Wx.bg3 : Colors.transparent),
        border: Border(
          bottom: BorderSide(
            color: widget.active ? Wx.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null)
            Icon(widget.icon, size: widget.dense ? 15 : 16, color: fg),
          if (widget.icon != null && widget.label != null)
            const SizedBox(width: 5),
          if (widget.label != null)
            Text(
              widget.label!,
              style: Wx.label.copyWith(
                color: fg,
                fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
        ],
      ),
    );

    if (widget.tooltip != null) {
      content = Tooltip(message: widget.tooltip!, child: content);
    }

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      ),
    );
  }
}

/// A dropdown styled to match [WxButton]. Used for the things that genuinely
/// belong behind a menu — sites, layers, tools — rather than the products,
/// which are on the bar itself.
class WxMenu<T> extends StatelessWidget {
  const WxMenu({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    this.label,
    this.icon,
    this.tooltip,
    this.active = false,
    this.caret = true,
    this.color,
    this.height = Wx.barH,
  });

  final List<PopupMenuEntry<T>> Function(BuildContext) itemBuilder;
  final void Function(T) onSelected;
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final bool active;
  final bool caret;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip ?? '',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: itemBuilder,
      padding: EdgeInsets.zero,
      child: _WxMenuFace(
        label: label,
        icon: icon,
        active: active,
        caret: caret,
        color: color,
        height: height,
      ),
    );
  }
}

class _WxMenuFace extends StatefulWidget {
  const _WxMenuFace({
    this.label,
    this.icon,
    this.active = false,
    this.caret = true,
    this.color,
    this.height = Wx.barH,
  });

  final String? label;
  final IconData? icon;
  final bool active;
  final bool caret;
  final Color? color;
  final double height;

  @override
  State<_WxMenuFace> createState() => _WxMenuFaceState();
}

class _WxMenuFaceState extends State<_WxMenuFace> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.color ?? (widget.active ? Wx.accent : Wx.text);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        color: _hover ? Wx.bg3 : Colors.transparent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) Icon(widget.icon, size: 16, color: fg),
            if (widget.icon != null && widget.label != null)
              const SizedBox(width: 5),
            if (widget.label != null)
              Text(widget.label!, style: Wx.label.copyWith(color: fg)),
            if (widget.caret)
              const Icon(Icons.arrow_drop_down, size: 15, color: Wx.textDim),
          ],
        ),
      ),
    );
  }
}

/// A dim all-caps heading inside a menu.
PopupMenuEntry<T> wxMenuHeading<T>(String text) => PopupMenuItem<T>(
      enabled: false,
      height: 22,
      child: Text(text, style: Wx.heading),
    );

/// One menu row: an optional tick column, a fixed-width code column, then the
/// name. The code column is what makes a long product list scannable —
/// REF/VEL/ZDR line up instead of hiding at the end of ragged labels.
PopupMenuItem<T> wxMenuItem<T>({
  required T value,
  required String label,
  String? code,
  bool checked = false,
  bool showCheck = true,
  Color? color,
}) {
  return PopupMenuItem<T>(
    value: value,
    height: 30,
    child: Row(
      children: [
        if (showCheck)
          SizedBox(
            width: 18,
            child: checked
                ? const Icon(Icons.check, size: 13, color: Wx.accent)
                : null,
          ),
        if (code != null)
          SizedBox(
            width: 42,
            child: Text(
              code,
              style: Wx.label.copyWith(
                color: checked ? Wx.accent : Wx.textDim,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Wx.label.copyWith(color: color ?? Wx.text),
          ),
        ),
      ],
    ),
  );
}

/// A small square status chip for the strips — replay, stale, error counts.
class WxChip extends StatelessWidget {
  const WxChip({
    super.key,
    required this.text,
    this.color = Wx.textDim,
    this.icon,
  });

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              height: 1.1,
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
