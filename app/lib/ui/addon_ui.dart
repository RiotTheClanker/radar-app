/// The addon parts of the interface: the manager dialog, and what tapping a
/// place or an overlay feature on the map shows.
///
/// Kept out of the pane and the workspace because both reach for it — a
/// pane opens the place sheet, the workspace's Tools menu opens the manager —
/// and neither owns the other, the same arrangement as `alert_sheets.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/addons.dart';
import '../data/geojson.dart';
import '../data/nexrad_sites.g.dart';
import 'geo.dart';
import 'workspace_state.dart';
import 'wx_theme.dart';

/// The glyph for a place group's `icon` name. Every name in [placeIcons]
/// has one; anything else was already turned into `pin` by the loader.
IconData placeIconData(String name) => switch (name) {
      'home' => Icons.home,
      'shelter' => Icons.shield,
      'school' => Icons.school,
      'hospital' => Icons.local_hospital,
      'fire' => Icons.local_fire_department,
      'police' => Icons.local_police,
      'spotter' => Icons.visibility,
      'camera' => Icons.videocam,
      'flag' => Icons.flag,
      'star' => Icons.star,
      'tower' => Icons.cell_tower,
      'airport' => Icons.flight,
      'water' => Icons.water_drop,
      _ => Icons.place,
    };

/// A place's detail: what it is, and where it sits relative to the radar.
///
/// The range and beam height are the point of putting a place on a radar
/// map rather than any map. "How high is the beam over the school" is the
/// question behind every "why doesn't the radar show the rotation I can
/// see": at 100 km the lowest tilt is already well over a kilometre up.
void showPlaceDetail(
  BuildContext context, {
  required PlaceGroup group,
  required Place place,
  required NexradSite site,
  double? elevationDeg,
}) {
  final (km, brg) = distanceBearing(LatLng(site.lat, site.lon), place.pos);
  // The pane's tilt if it has one, otherwise the lowest routine cut — which
  // is the most useful answer for "what can the radar see here" anyway.
  final el = elevationDeg ?? 0.5;
  final kft = beamHeightM(km * 1000, el) * 3.28084 / 1000.0;
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(placeIconData(group.icon), size: 18, color: group.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    place.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Wx.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(group.name, style: Wx.labelDim),
            if (place.notes != null) ...[
              const SizedBox(height: 10),
              Text(
                place.notes!,
                style: TextStyle(color: Wx.text, fontSize: 12.5, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'From ${site.icao}: ${km.toStringAsFixed(1)} km '
              '(${(km * 0.621371).toStringAsFixed(1)} mi) at ${brg.round()}°',
              style: Wx.mono,
            ),
            const SizedBox(height: 4),
            Text(
              'The ${el.toStringAsFixed(1)}° beam passes about '
              '${kft.toStringAsFixed(1)} kft above the radar here',
              style: Wx.mono,
            ),
            const SizedBox(height: 4),
            Text(
              '${place.pos.latitude.toStringAsFixed(4)}, '
              '${place.pos.longitude.toStringAsFixed(4)}',
              style: Wx.mono.copyWith(color: Wx.textDim),
            ),
          ],
        ),
      ),
    ),
  );
}

/// What an overlay's point feature carries.
void showFeatureDetail(BuildContext context, AddonOverlay o, GeoPoint p) {
  final props = [
    for (final e in p.properties.entries)
      // Styling keys are how it looks, not what it is.
      if (!_styleKeys.contains(e.key) && e.value != null) e,
  ];
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.style.label ?? o.name,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Wx.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(o.name, style: Wx.labelDim),
            const SizedBox(height: 10),
            for (final e in props.take(20))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('${e.key}: ${e.value}', style: Wx.mono),
              ),
          ],
        ),
      ),
    ),
  );
}

const _styleKeys = {
  'stroke', 'stroke-width', 'stroke-opacity', 'fill', 'fill-opacity', //
  'marker-color', 'marker-size', 'marker-symbol',
};

/// Addons: what is installed, what each adds, what went wrong, and the
/// switches to turn them on and off, install one from a link, or remove one.
class AddonManager extends StatefulWidget {
  const AddonManager({super.key, required this.shared});

  final WorkspaceState shared;

  @override
  State<AddonManager> createState() => _AddonManagerState();
}

class _AddonManagerState extends State<AddonManager> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  WorkspaceState get _shared => widget.shared;

  @override
  void initState() {
    super.initState();
    _shared.addListener(_changed);
  }

  @override
  void dispose() {
    _shared.removeListener(_changed);
    _url.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _say(String m, {bool error = false}) {
    setState(() {
      _message = m;
      _messageIsError = error;
    });
  }

  Future<void> _install() async {
    final dir = _shared.addonFolder;
    if (dir == null || _url.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final a = await installAddonFromUrl(_url.text, dir);
      _shared.reloadAddons();
      _url.clear();
      _say('Installed "${a.name}" — ${a.summary}');
    } catch (e) {
      _say(e is FormatException ? e.message : '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Addon a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Wx.bg1,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Wx.line),
          borderRadius: BorderRadius.zero,
        ),
        title: Text('Remove "${a.name}"?', style: Wx.label),
        content: Text(
          'Deletes ${a.path}',
          style: Wx.labelDim,
        ),
        actions: [
          WxButton(
            label: 'Cancel',
            onTap: () => Navigator.of(context).pop(false),
          ),
          WxButton(
            label: 'Remove',
            color: Wx.danger,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      removeAddon(a);
      _shared.reloadAddons();
      _say('Removed "${a.name}"');
    } catch (e) {
      _say('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final addons = _shared.addons;
    final errors = _shared.addonErrors;
    return Dialog(
      backgroundColor: Wx.bg1,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Wx.line),
        borderRadius: BorderRadius.zero,
      ),
      child: SizedBox(
        width: 520,
        height: 600,
        child: Column(
          children: [
            WxBar(
              leading: [
                const SizedBox(width: 6),
                Text('ADDONS', style: Wx.heading),
              ],
              trailing: [
                WxButton(
                  icon: Icons.refresh,
                  tooltip: 'Read the addons folder again',
                  dense: true,
                  onTap: () {
                    _shared.reloadAddons();
                    _say('Reloaded ${_shared.addons.length} addons');
                  },
                ),
                WxButton(
                  icon: Icons.close,
                  tooltip: 'Close',
                  dense: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  if (addons.isEmpty && errors.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No addons yet. An addon is a JSON file that adds '
                        'radar sites, map overlays, places or themes — '
                        'install one from a link below, or drop files in '
                        'the folder.',
                        style: Wx.labelDim.copyWith(height: 1.4),
                      ),
                    ),
                  for (final a in addons) _addonTile(a),
                  for (final c in _shared.addonConflicts)
                    _problem(c, Wx.warn),
                  for (final e in errors.entries)
                    _problem('${_basename(e.key)}: ${e.value}', Wx.danger),
                ],
              ),
            ),
            Container(height: 1, color: Wx.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _url,
                      style: Wx.label,
                      enabled: !_busy,
                      onSubmitted: (_) => unawaited(_install()),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'https://… link to an addon .json',
                        hintStyle: Wx.labelDim,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: Wx.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: Wx.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: Wx.accent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  WxButton(
                    label: _busy ? 'Installing…' : 'Install',
                    icon: Icons.download,
                    onTap: _busy ? null : () => unawaited(_install()),
                  ),
                ],
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _message!,
                    style: Wx.labelDim.copyWith(
                      color: _messageIsError ? Wx.danger : Wx.good,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  // Where to put files by hand. Selectable so it can be
                  // copied into a file manager; there is no plugin here to
                  // open one.
                  'Folder: ${_shared.addonFolder?.path ?? '—'}',
                  style: Wx.labelDim.copyWith(fontSize: 10.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addonTile(Addon a) {
    final on = _shared.isAddonEnabled(a);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: Wx.bg2,
        border: Border(
          left: BorderSide(color: on ? Wx.accent : Wx.line, width: 2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: a.name,
                      style: Wx.label.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (a.version.isNotEmpty)
                      TextSpan(text: '  ${a.version}', style: Wx.labelDim),
                    if (a.author.isNotEmpty)
                      TextSpan(text: '  · ${a.author}', style: Wx.labelDim),
                  ]),
                ),
                if (a.description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(a.description, style: Wx.labelDim),
                ],
                const SizedBox(height: 3),
                Text(
                  a.summary,
                  style: Wx.labelDim.copyWith(color: Wx.textFaint),
                ),
                for (final w in a.warnings.take(8))
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '⚠ $w',
                      style: Wx.labelDim.copyWith(color: Wx.warn),
                    ),
                  ),
                if (a.warnings.length > 8)
                  Text(
                    '… and ${a.warnings.length - 8} more',
                    style: Wx.labelDim.copyWith(color: Wx.warn),
                  ),
              ],
            ),
          ),
          Switch(
            value: on,
            onChanged: (v) => _shared.setAddonEnabled(a, v),
          ),
          WxButton(
            icon: Icons.delete_outline,
            tooltip: 'Remove this addon',
            dense: true,
            onTap: () => unawaited(_remove(a)),
          ),
        ],
      ),
    );
  }

  Widget _problem(String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(text, style: Wx.labelDim.copyWith(color: color)),
      );

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).last;
}
