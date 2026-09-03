/// The alert detail and alert list sheets.
///
/// Pulled out of the screen because both ends now need them: a pane opens the
/// detail sheet when you tap a warning polygon, and the workspace's layers
/// menu opens the full list. Neither owns the other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import 'wx_theme.dart';

/// Bounding box of an alert's polygons, or null if it has none to draw.
LatLngBounds? alertBounds(WeatherAlert a) {
  var north = -90.0, south = 90.0, east = -180.0, west = 180.0;
  for (final ring in a.polygons) {
    for (final p in ring) {
      if (p.latitude > north) north = p.latitude;
      if (p.latitude < south) south = p.latitude;
      if (p.longitude > east) east = p.longitude;
      if (p.longitude < west) west = p.longitude;
    }
  }
  if (north <= south || east <= west) return null;
  return LatLngBounds(LatLng(north, west), LatLng(south, east));
}

void showAlertSheet(BuildContext context, WeatherAlert alert) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.45,
      minChildSize: 0.2,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Row(
            children: [
              Container(width: 10, height: 10, color: alert.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  alert.event,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Wx.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (alert.headline.isNotEmpty)
            Text(
              alert.headline,
              style: const TextStyle(fontSize: 13, color: Wx.textDim),
            ),
          const SizedBox(height: 12),
          Text(
            alert.description,
            style: const TextStyle(fontSize: 12.5, height: 1.45, color: Wx.text),
          ),
        ],
      ),
    ),
  );
}

/// Every active alert, grouped by category. This is the only place the
/// county-issued ones show up at all, since they have no polygon to draw.
///
/// [onZoom] is handed an alert the caller can frame on the map; it is only
/// offered for alerts that actually have an outline.
/// Alerts stack. A tornado warning inside a severe thunderstorm watch inside
/// a flood advisory is three polygons over the same ground, and a tap that
/// silently picked one of them was picking by draw order — which is not the
/// one anyone meant.
///
/// Ordered by how much it matters: warnings, then watches, then advisories,
/// and within a category the one expiring soonest first. So the thing you
/// most likely tapped for is at the top even though the list exists precisely
/// because we cannot know which you meant.
List<WeatherAlert> orderByUrgency(List<WeatherAlert> alerts) {
  final out = List<WeatherAlert>.of(alerts);
  out.sort((a, b) {
    final byCat = a.category.index.compareTo(b.category.index);
    if (byCat != 0) return byCat;
    final ax = a.expires;
    final bx = b.expires;
    if (ax == null && bx == null) return a.event.compareTo(b.event);
    if (ax == null) return 1;
    if (bx == null) return -1;
    return ax.compareTo(bx);
  });
  return out;
}

/// Everything under one tap, when more than one thing is.
///
/// A single alert opens straight to its text — a disambiguation step for an
/// unambiguous tap is a step for nothing. Two or more, and this asks.
void showAlertPicker(BuildContext context, List<WeatherAlert> alerts) {
  if (alerts.isEmpty) return;
  if (alerts.length == 1) {
    showAlertSheet(context, alerts.first);
    return;
  }
  final ordered = orderByUrgency(alerts);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              '${ordered.length} alerts here',
              style: Wx.heading,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'They overlap where you tapped. Pick one to read it.',
              style: Wx.labelDim,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              children: [
                for (final a in ordered)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 8),
                      color: a.color,
                    ),
                    title: Text(a.event, style: Wx.label),
                    subtitle: Text(
                      a.areaDesc.isEmpty ? a.headline : a.areaDesc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 10.5, color: Wx.textDim),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: Wx.textDim,
                    ),
                    // Pop with the sheet's own context, then open against the
                    // caller's — the sheet context is deactivated by the pop,
                    // and pushing a route through it afterwards is undefined.
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      showAlertSheet(context, a);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void showAlertList(
  BuildContext context,
  List<WeatherAlert> alerts, {
  required void Function(WeatherAlert) onZoom,
}) {
  final byCat = <AlertCategory, List<WeatherAlert>>{};
  for (final a in alerts) {
    byCat.putIfAbsent(a.category, () => []).add(a);
  }
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.25,
      maxChildSize: 0.95,
      builder: (sheetContext, controller) {
        if (alerts.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('Nothing active right now.', style: Wx.labelDim),
            ),
          );
        }
        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            for (final c in AlertCategory.values) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                child: Text(
                  '${c.label.toUpperCase()}  ·  '
                  '${(byCat[c] ?? const []).length}',
                  style: Wx.heading,
                ),
              ),
              // Say so explicitly. A missing heading looks the same as a
              // broken feature, and "no watches right now" is a real and
              // common answer.
              if ((byCat[c] ?? const []).isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 4, 4),
                  child: Text('none active', style: Wx.labelDim),
                ),
              for (final a in byCat[c] ?? const <WeatherAlert>[])
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 8),
                    color: a.color,
                  ),
                  title: Text(a.event, style: Wx.label),
                  subtitle: Text(
                    a.areaDesc.isEmpty ? a.headline : a.areaDesc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Wx.textDim),
                  ),
                  // Only the drawn ones can be zoomed to.
                  trailing: a.hasPolygon
                      ? const Icon(Icons.crop_free, size: 14, color: Wx.textDim)
                      : null,
                  // Pop with the sheet's own context, then reopen against the
                  // caller's — the sheet context is deactivated by the pop,
                  // and pushing a route through it afterwards is undefined.
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    if (a.hasPolygon) onZoom(a);
                    showAlertSheet(context, a);
                  },
                ),
            ],
          ],
        );
      },
    ),
  );
}
