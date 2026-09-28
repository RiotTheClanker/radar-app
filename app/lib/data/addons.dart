/// Addons: JSON files that add radar sites, map overlays, ground locations,
/// themes and colour tables, for the uses the app does not ship for.
///
/// A county emergency manager wants the county's roads and shelters on the
/// map. A university has a radar nobody put on AWS. A chase team keeps its
/// own tile server. None of that belongs in the app for everyone, and all of
/// it is data rather than code — so an addon is a manifest, never a script.
/// Nothing in one can run; the worst a bad addon can do is point at a URL
/// that does not answer.
///
/// An addon is either a single `<name>.json` in the addons folder, or a
/// folder holding an `addon.json` next to the files it refers to. The format
/// is documented in docs/addons.md.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geojson.dart';
import 'identity.dart';
import 'nexrad_sites.g.dart';
import 'radar_source.dart';

/// The manifest format this build reads. A file declaring a newer one still
/// loads what it can, with a warning that it was written for a newer app.
const addonFormat = 1;

/// Names the addon manager uses for itself inside the addons folder, and
/// which therefore are not addons.
const _reservedNames = {'README.txt'};

// ------------------------------------------------------------- models ----

enum OverlayKind { tiles, wms, geojson }

/// A map layer an addon adds.
class AddonOverlay {
  const AddonOverlay({
    required this.key,
    required this.addonId,
    required this.name,
    required this.kind,
    this.url,
    this.file,
    this.inline,
    this.opacity = 1.0,
    this.stroke = const Color(0xFFFFD54F),
    this.fill,
    this.width = 1.5,
    this.labelKey,
    this.refreshMinutes = 0,
    this.attribution,
    this.aboveRadar = false,
    this.visibleByDefault = true,
    this.minZoom,
    this.maxZoom,
    this.bounds,
    this.wms,
  });

  /// `addonId/overlayId`, unique across every loaded addon.
  final String key;
  final String addonId;
  final String name;
  final OverlayKind kind;

  /// Tile URL template (`{z}/{x}/{y}`), or where to fetch the GeoJSON from.
  final String? url;

  /// A GeoJSON file beside the manifest, already resolved to a full path.
  final String? file;

  /// GeoJSON written straight into the manifest.
  final String? inline;

  final double opacity;
  final Color stroke;
  final Color? fill;
  final double width;
  final String? labelKey;

  /// How often to refetch a GeoJSON [url]; 0 is fetch once. Clamped to at
  /// least a minute, because someone's own server is still a server.
  final int refreshMinutes;

  /// Required by most tile providers, and shown with the basemap's when on.
  final String? attribution;

  /// Drawn over the radar instead of under it. Boundaries and roads want to
  /// be read through the echoes; a satellite or model layer wants to sit
  /// beneath them, the way the CAPE layer does.
  final bool aboveRadar;

  final bool visibleByDefault;
  final double? minZoom;
  final double? maxZoom;

  /// Where a tile or WMS layer has anything to draw: south, west, north,
  /// east. Tiles outside it are never requested — a Canadian mosaic has
  /// nothing to say about Kansas, and asking for it on every pan is a
  /// stranger's server answering with blank images.
  final ({double south, double west, double north, double east})? bounds;

  /// How to ask a WMS server for tiles, for [OverlayKind.wms].
  final WmsSpec? wms;

  /// The URL a tile or WMS layer is fetched with right now.
  ///
  /// A layer with a refresh interval gets a stamp that changes once per
  /// interval. Tiles are cached by URL, so without it a radar mosaic drawn
  /// at noon would still be noon's at six.
  String? tileUrlAt(DateTime now) {
    final u = url;
    final stamp = refreshStamp(now);
    if (u == null || stamp == null) return u;
    return '$u${u.contains('?') ? '&' : '?'}_=$stamp';
  }

  /// A number that changes once per [refreshMinutes], or null for a layer
  /// that is fetched once.
  int? refreshStamp(DateTime now) {
    if (refreshMinutes <= 0) return null;
    final period = refreshMinutes.clamp(1, 1440) * 60000;
    return now.millisecondsSinceEpoch ~/ period;
  }
}

/// The request parameters of a WMS layer.
class WmsSpec {
  const WmsSpec({
    required this.layers,
    this.styles = const [],
    this.format = 'image/png',
    this.version = '1.3.0',
    this.transparent = true,
    this.params = const {},
  });

  final List<String> layers;
  final List<String> styles;
  final String format;
  final String version;
  final bool transparent;

  /// Anything else the server wants on the query string (`TIME`, a key).
  final Map<String, String> params;
}

/// One ground location: a shelter, a spotter post, a school, home.
class Place {
  const Place(this.name, this.pos, {this.notes});
  final String name;
  final LatLng pos;
  final String? notes;
}

/// A set of places switched on and off together.
class PlaceGroup {
  const PlaceGroup({
    required this.key,
    required this.addonId,
    required this.name,
    required this.places,
    this.icon = 'pin',
    this.color = const Color(0xFFFFFFFF),
    this.visibleByDefault = true,
  });

  /// `addonId/groupId`.
  final String key;
  final String addonId;
  final String name;
  final List<Place> places;

  /// One of [placeIcons]. A name rather than a code point so a manifest
  /// stays readable and a typo is caught as a warning, not drawn as a box.
  final String icon;
  final Color color;
  final bool visibleByDefault;
}

/// The icon names a place group may use. The UI maps each to a glyph.
const placeIcons = {
  'pin', 'home', 'shelter', 'school', 'hospital', 'fire', 'police', //
  'spotter', 'camera', 'flag', 'star', 'tower', 'airport', 'water',
};

/// A chrome colour scheme. Raw colours by key; the UI merges them over its
/// own palette (`WxPalette.keys` lists what can be set).
class ThemeSpec {
  const ThemeSpec({
    required this.key,
    required this.addonId,
    required this.name,
    required this.colors,
    this.basemap,
  });

  /// `addonId/themeId`.
  final String key;
  final String addonId;
  final String name;
  final Map<String, Color> colors;

  /// A basemap to switch to with the theme, by its label. A red night theme
  /// over a bright satellite basemap has undone itself.
  final String? basemap;
}

/// The keys a theme may set. Mirrors `WxPalette.keys` in the UI layer, which
/// this layer may not import; a test holds the two together.
const themeColorKeys = {
  'bg0', 'bg1', 'bg2', 'bg3', 'line', 'lineBright', //
  'text', 'textDim', 'textFaint', 'accent', 'warn', 'danger', 'good',
};

class Addon {
  const Addon({
    required this.id,
    required this.name,
    required this.path,
    this.version = '',
    this.author = '',
    this.description = '',
    this.homepage,
    this.sites = const [],
    this.overlays = const [],
    this.places = const [],
    this.themes = const [],
    this.palettes = const [],
    this.warnings = const [],
    this.builtIn = false,
    this.enabledByDefault = true,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String? homepage;

  /// The manifest file, or the folder for a folder addon — what removing the
  /// addon deletes.
  final String path;

  final List<AddonSite> sites;
  final List<AddonOverlay> overlays;
  final List<PlaceGroup> places;
  final List<ThemeSpec> themes;

  /// `.pal` files the addon ships, as full paths. They join the colour
  /// tables in the Tools menu.
  final List<String> palettes;

  /// What was skipped or looked wrong. Shown in the addon manager, because a
  /// layer that silently fails to appear is indistinguishable from a bug.
  final List<String> warnings;

  /// Shipped inside the app rather than installed. Can be switched off but
  /// not removed, and is replaced by the next version of the app rather than
  /// by reinstalling.
  final bool builtIn;

  /// Whether it is on before anyone has touched its switch. Built-in addons
  /// are extras most people will not want — a second radar network, a
  /// theme — so they ship off and wait to be asked for.
  final bool enabledByDefault;

  String get summary {
    final parts = <String>[
      if (sites.isNotEmpty) _n(sites.length, 'radar site'),
      if (overlays.isNotEmpty) _n(overlays.length, 'overlay'),
      if (places.isNotEmpty)
        _n(places.fold(0, (a, g) => a + g.places.length), 'place'),
      if (themes.isNotEmpty) _n(themes.length, 'theme'),
      if (palettes.isNotEmpty) _n(palettes.length, 'colour table'),
    ];
    return parts.isEmpty ? 'nothing to add' : parts.join(' · ');
  }

  static String _n(int n, String what) => '$n $what${n == 1 ? '' : 's'}';
}

// ------------------------------------------------------------ parsing ----

final _idRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

/// Parse one manifest.
///
/// [baseDir] is where relative `file` references resolve from — the addon's
/// folder, or null for an addon with nowhere to keep files (one installed
/// from a URL), in which case a `file` reference is a warning.
///
/// Throws [FormatException] only when there is no addon here at all: not a
/// JSON object, or no usable `id`/`name`. Everything else — a site missing
/// its latitude, an overlay of an unknown type — is skipped with a warning,
/// so one mistake does not take the rest of someone's work down with it.
Addon parseAddon(
  String text, {
  required String path,
  String? baseDir,
  bool builtIn = false,
}) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('not valid JSON: ${e.message}');
  }
  if (doc is! Map<String, dynamic>) {
    throw const FormatException('an addon is a JSON object');
  }
  final id = doc['id'];
  if (id is! String || !_idRe.hasMatch(id)) {
    throw const FormatException(
        '"id" is required: letters, digits, dot, dash or underscore');
  }
  final name = doc['name'];
  if (name is! String || name.trim().isEmpty) {
    throw const FormatException('"name" is required');
  }

  final warnings = <String>[];
  const known = {
    'id', 'name', 'version', 'author', 'description', 'homepage', //
    'format', 'sites', 'overlays', 'places', 'themes', 'palettes', 'enabled',
  };
  for (final k in doc.keys) {
    if (!known.contains(k)) warnings.add('unknown field "$k" ignored');
  }
  final format = doc['format'];
  if (format is num && format > addonFormat) {
    warnings.add('written for addon format $format; this app reads '
        '$addonFormat, so newer features are ignored');
  }

  final ctx = _Ctx(id, baseDir, warnings);
  return Addon(
    id: id,
    name: name.trim(),
    path: path,
    version: _str(doc['version']) ?? '',
    author: _str(doc['author']) ?? '',
    description: _str(doc['description']) ?? '',
    homepage: _str(doc['homepage']),
    sites: _list(doc['sites'], 'sites', ctx, _site),
    overlays: _list(doc['overlays'], 'overlays', ctx, _overlay),
    places: _list(doc['places'], 'places', ctx, _placeGroup),
    themes: _list(doc['themes'], 'themes', ctx, _theme),
    palettes: _list(doc['palettes'], 'palettes', ctx, _palette),
    warnings: warnings,
    builtIn: builtIn,
    enabledByDefault: doc['enabled'] != false,
  );
}

class _Ctx {
  _Ctx(this.addonId, this.baseDir, this.warnings);
  final String addonId;
  final String? baseDir;
  final List<String> warnings;

  /// A path the manifest named, resolved inside the addon's folder.
  ///
  /// Refuses anything that climbs out of it. An addon is somebody else's
  /// file; `"file": "../../.ssh/id_rsa"` should not be something it can put
  /// on a map, or send to a server as a "GeoJSON overlay" it then fetches.
  String? file(String rel, String what) {
    final base = baseDir;
    if (base == null) {
      warnings.add('$what: "file" needs the addon to be a folder; '
          'use "url" for an addon installed from the web');
      return null;
    }
    final normal = rel.replaceAll('\\', '/');
    if (normal.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normal) ||
        normal.split('/').contains('..')) {
      warnings.add('$what: "$rel" is outside the addon folder');
      return null;
    }
    return '$base/$normal';
  }
}

extension on _Ctx {
  /// A folder a data source reads from.
  ///
  /// Wider than [file]: a radar's data rarely lives inside the addon, so an
  /// absolute path or one under `~/` is accepted as well as one relative to
  /// the addon folder. Only read, never sent anywhere — the files go to the
  /// decoder and nowhere else — and a relative path is still held inside the
  /// addon folder, so a copied addon cannot quietly aim at someone's home.
  String? folder(String raw, String what) {
    final p = raw.replaceAll('\\', '/');
    if (p.startsWith('~/')) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'];
      if (home == null) {
        warnings.add('$what: "~" has no home folder to mean here');
        return null;
      }
      return '$home/${p.substring(2)}';
    }
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(p)) return p;
    return file(p, what);
  }
}

List<T> _list<T>(
  Object? v,
  String field,
  _Ctx ctx,
  T? Function(Object?, int, _Ctx) item,
) {
  if (v == null) return const [];
  if (v is! List) {
    ctx.warnings.add('"$field" should be a list');
    return const [];
  }
  final out = <T>[];
  for (var i = 0; i < v.length; i++) {
    final r = item(v[i], i, ctx);
    if (r != null) out.add(r);
  }
  return out;
}

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

double? _dbl(Object? v) => v is num ? v.toDouble() : null;

String _label(Map m, String kind, int i) =>
    '$kind ${_str(m['id']) ?? _str(m['name']) ?? '#${i + 1}'}';

AddonSite? _site(Object? v, int i, _Ctx ctx) {
  if (v is! Map) {
    ctx.warnings.add('site #${i + 1} is not an object');
    return null;
  }
  final what = _label(v, 'site', i);
  final id = _str(v['id'])?.toUpperCase();
  final lat = _dbl(v['lat']);
  final lon = _dbl(v['lon']);
  if (id == null || !_idRe.hasMatch(id)) {
    ctx.warnings.add('$what: needs an "id" like "KTLX" or "XOKC"');
    return null;
  }
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
    ctx.warnings.add('$what: needs "lat" and "lon" in degrees');
    return null;
  }
  final builtIn = nexradSites.where((s) => s.icao == id).firstOrNull;
  final l2 = _source(v['level2'], '$what level2', ctx);
  final l3 = _source(v['level3'], '$what level3', ctx);
  final open = _source(v['open'], '$what open', ctx);
  if (open != null && (l2 != null || l3 != null)) {
    ctx.warnings.add('$what: has an "open" source, which is used for every '
        'product — its level2/level3 sources are ignored');
  }
  if (open != null &&
      !open.url.contains('{product}') &&
      !open.prefix.contains('{product}')) {
    ctx.warnings.add('$what: open source has no {product} in it, so every '
        'product button will show the same files');
  }
  if (l3 != null &&
      !l3.url.contains('{product}') &&
      !l3.prefix.contains('{product}')) {
    ctx.warnings.add('$what: level3 source has no {product} in it, so every '
        'Level 3 product will show the same files');
  }
  if (builtIn == null && l2 == null && l3 == null && open == null) {
    ctx.warnings.add('$what: a new site needs a "level2", "level3" or "open" '
        'source — it has nowhere to get data from');
  }
  final shortId = _str(v['shortId']);
  final codes = <String, String>{};
  final rawCodes = v['products'];
  if (rawCodes is Map) {
    rawCodes.forEach((k, val) {
      final c = _str(val);
      if (k is String && k.trim().isNotEmpty && c != null) {
        codes[k.trim().toUpperCase()] = c.toUpperCase();
      } else {
        ctx.warnings.add('$what: products "$k" should map to a product code');
      }
    });
  } else if (rawCodes != null) {
    ctx.warnings.add('$what: "products" should be an object like '
        '{"N0B": "TZ0"}');
  }
  if (codes.isNotEmpty && open != null) {
    ctx.warnings.add('$what: "products" renames Level 3 codes, and an open '
        'source has none — it is ignored');
  }
  final isTdwr = builtIn?.isTdwr ?? v['tdwr'] == true;
  return AddonSite(
    id,
    _str(v['name']) ?? builtIn?.name ?? id,
    _str(v['state']) ?? builtIn?.state ?? '',
    lat,
    lon,
    (v['elevFt'] as num?)?.round() ?? builtIn?.elevFt ?? 0,
    isTdwr,
    addonId: ctx.addonId,
    level2: l2,
    level3: l3,
    open: open,
    attribution: _str(v['attribution']),
    // A TDWR id is in the built-in table but has nothing in NOAA's Level 2
    // bucket to fall back to, so a missing level is an error that says so
    // rather than an empty listing that looks like a quiet radar.
    overridesBuiltIn: builtIn != null && !builtIn.isTdwr,
    shortIdOverride: shortId,
    productCodes: open != null ? const {} : codes,
  );
}

DataSource? _source(Object? v, String what, _Ctx ctx) {
  if (v == null) return null;
  if (v is! Map) {
    ctx.warnings.add('$what: should be an object');
    return null;
  }
  final kind = switch (v['type']) {
    's3' => SourceKind.s3,
    'index' || null => SourceKind.listing,
    'folder' => SourceKind.folder,
    _ => null,
  };
  if (kind == null) {
    ctx.warnings.add('$what: "type" must be "s3", "index" or "folder"');
    return null;
  }
  final String url;
  if (kind == SourceKind.folder) {
    final path = _str(v['path']);
    if (path == null) {
      ctx.warnings.add('$what: a folder source needs a "path"');
      return null;
    }
    final resolved = ctx.folder(path, what);
    if (resolved == null) return null;
    url = resolved;
  } else {
    final u = _str(v['url']);
    if (u == null || !(u.startsWith('https://') || u.startsWith('http://'))) {
      ctx.warnings.add('$what: needs an http(s) "url"');
      return null;
    }
    url = u;
  }
  if (url.startsWith('http://')) {
    ctx.warnings.add('$what: plain http — data and any headers travel '
        'unencrypted');
  }
  RegExp? match;
  final m = _str(v['match']);
  if (m != null) {
    try {
      match = RegExp(m);
    } on FormatException {
      ctx.warnings.add('$what: "match" is not a valid regular expression');
      return null;
    }
  }
  final headers = <String, String>{};
  final h = v['headers'];
  if (h is Map) {
    h.forEach((k, val) {
      if (k is String && val is String) headers[k] = val;
    });
  }
  return DataSource(
    kind: kind,
    url: url,
    prefix: _str(v['prefix']) ?? '',
    match: match,
    headers: headers,
    days: (v['days'] as num?)?.round().clamp(1, 14) ?? 2,
    attribution: _str(v['attribution']),
  );
}

AddonOverlay? _overlay(Object? v, int i, _Ctx ctx) {
  if (v is! Map) {
    ctx.warnings.add('overlay #${i + 1} is not an object');
    return null;
  }
  final what = _label(v, 'overlay', i);
  final id = _str(v['id']) ?? 'overlay${i + 1}';
  final name = _str(v['name']) ?? id;
  final kind = switch (v['type']) {
    'tiles' => OverlayKind.tiles,
    'wms' => OverlayKind.wms,
    'geojson' => OverlayKind.geojson,
    _ => null,
  };
  if (kind == null) {
    ctx.warnings.add('$what: "type" must be "tiles", "wms" or "geojson"');
    return null;
  }
  final url = _str(v['url']);
  final fileRel = _str(v['file']);
  final file = fileRel == null ? null : ctx.file(fileRel, what);
  String? inline;
  if (v['data'] is Map) inline = jsonEncode(v['data']);

  WmsSpec? wms;
  if (kind == OverlayKind.tiles) {
    if (url == null || !url.contains('{z}')) {
      ctx.warnings.add('$what: tiles need a "url" with {z}, {x} and {y}');
      return null;
    }
  } else if (kind == OverlayKind.wms) {
    wms = _wms(v, what, ctx);
    if (url == null || wms == null) {
      if (url == null) ctx.warnings.add('$what: wms needs the server\'s "url"');
      return null;
    }
  } else if (url == null && file == null && inline == null) {
    ctx.warnings.add('$what: geojson needs a "url", a "file" or "data"');
    return null;
  }
  if (url != null && !(url.startsWith('https://') || url.startsWith('http://'))) {
    ctx.warnings.add('$what: "url" must be http(s)');
    return null;
  }
  final stroke = v['stroke'] == null ? null : parseColor(v['stroke']);
  if (v['stroke'] != null && stroke == null) {
    ctx.warnings.add('$what: "stroke" is not a #RRGGBB colour');
  }
  final fill = v['fill'] == null ? null : parseColor(v['fill']);
  if (v['fill'] != null && fill == null) {
    ctx.warnings.add('$what: "fill" is not a #RRGGBB colour');
  }
  return AddonOverlay(
    key: '${ctx.addonId}/$id',
    addonId: ctx.addonId,
    name: name,
    kind: kind,
    url: url,
    file: file,
    inline: inline,
    opacity: (_dbl(v['opacity']) ?? 1.0).clamp(0.0, 1.0),
    stroke: stroke ?? const Color(0xFFFFD54F),
    fill: fill,
    width: (_dbl(v['width']) ?? 1.5).clamp(0.5, 8.0),
    labelKey: _str(v['label']),
    refreshMinutes: (v['refreshMinutes'] as num?)?.round() ?? 0,
    attribution: _str(v['attribution']),
    aboveRadar: v['above'] == true,
    visibleByDefault: v['visible'] != false,
    minZoom: _dbl(v['minZoom']),
    maxZoom: _dbl(v['maxZoom']),
    bounds: _bounds(v['bounds'], what, ctx),
    wms: wms,
  );
}

WmsSpec? _wms(Map v, String what, _Ctx ctx) {
  List<String> names(Object? x) => switch (x) {
        String s => [
            for (final p in s.split(','))
              if (p.trim().isNotEmpty) p.trim(),
          ],
        List l => [for (final p in l) if (_str(p) != null) _str(p)!],
        _ => const [],
      };
  final layers = names(v['layers']);
  if (layers.isEmpty) {
    ctx.warnings.add('$what: wms needs "layers" — the layer name(s) the '
        'server\'s GetCapabilities lists');
    return null;
  }
  final params = <String, String>{};
  final p = v['params'];
  if (p is Map) {
    p.forEach((k, val) {
      if (k is String && (val is String || val is num || val is bool)) {
        params[k] = '$val';
      }
    });
  }
  return WmsSpec(
    layers: layers,
    styles: names(v['styles']),
    format: _str(v['format']) ?? 'image/png',
    version: _str(v['version']) ?? '1.3.0',
    transparent: v['transparent'] != false,
    params: params,
  );
}

({double south, double west, double north, double east})? _bounds(
  Object? v,
  String what,
  _Ctx ctx,
) {
  if (v == null) return null;
  final n = v is List ? [for (final x in v) _dbl(x)] : const <double?>[];
  if (n.length != 4 ||
      n.contains(null) ||
      n[0]! >= n[2]! ||
      n[0]!.abs() > 90 ||
      n[2]!.abs() > 90 ||
      n[1]!.abs() > 180 ||
      n[3]!.abs() > 180) {
    ctx.warnings.add('$what: "bounds" should be [south, west, north, east] '
        'in degrees');
    return null;
  }
  return (south: n[0]!, west: n[1]!, north: n[2]!, east: n[3]!);
}

PlaceGroup? _placeGroup(Object? v, int i, _Ctx ctx) {
  if (v is! Map) {
    ctx.warnings.add('place group #${i + 1} is not an object');
    return null;
  }
  final what = _label(v, 'places', i);
  final id = _str(v['id']) ?? 'places${i + 1}';
  final places = <Place>[];

  final items = v['items'];
  if (items is List) {
    for (var k = 0; k < items.length; k++) {
      final p = items[k];
      final lat = p is Map ? _dbl(p['lat']) : null;
      final lon = p is Map ? _dbl(p['lon']) : null;
      if (p is! Map || lat == null || lon == null) {
        ctx.warnings.add('$what: item #${k + 1} needs "lat" and "lon"');
        continue;
      }
      places.add(Place(
        _str(p['name']) ?? 'Place ${k + 1}',
        LatLng(lat, lon),
        notes: _str(p['notes']),
      ));
    }
  }

  final fileRel = _str(v['file']);
  if (fileRel != null) {
    final path = ctx.file(fileRel, what);
    if (path != null) {
      try {
        final text = File(path).readAsStringSync();
        places.addAll(fileRel.toLowerCase().endsWith('.csv')
            ? parsePlacesCsv(text)
            : placesFromGeoJson(text));
      } catch (e) {
        ctx.warnings.add('$what: could not read "$fileRel" ($e)');
      }
    }
  }

  if (places.isEmpty) {
    ctx.warnings.add('$what: has no places');
    return null;
  }
  var icon = _str(v['icon']) ?? 'pin';
  if (!placeIcons.contains(icon)) {
    ctx.warnings.add('$what: unknown icon "$icon", using "pin" '
        '(one of ${placeIcons.join(', ')})');
    icon = 'pin';
  }
  return PlaceGroup(
    key: '${ctx.addonId}/$id',
    addonId: ctx.addonId,
    name: _str(v['name']) ?? id,
    places: places,
    icon: icon,
    color: parseColor(v['color']) ?? const Color(0xFFFFFFFF),
    visibleByDefault: v['visible'] != false,
  );
}

ThemeSpec? _theme(Object? v, int i, _Ctx ctx) {
  if (v is! Map) {
    ctx.warnings.add('theme #${i + 1} is not an object');
    return null;
  }
  final what = _label(v, 'theme', i);
  final id = _str(v['id']) ?? 'theme${i + 1}';
  final colors = <String, Color>{};
  final raw = v['colors'];
  if (raw is Map) {
    raw.forEach((k, val) {
      if (!themeColorKeys.contains(k)) {
        ctx.warnings.add('$what: unknown colour "$k"');
        return;
      }
      final c = parseColor(val);
      if (c == null) {
        ctx.warnings.add('$what: "$k" is not a #RRGGBB colour');
        return;
      }
      colors[k as String] = c;
    });
  }
  if (colors.isEmpty) {
    ctx.warnings.add('$what: sets no colours');
    return null;
  }
  // The app is used outdoors at night during severe weather; a light
  // background washes out the radar palettes and wrecks night vision
  // (ui-contract.md, invariant 2). Allowed — someone may want it for a
  // projector in a lit room — but said.
  final bg = colors['bg0'];
  if (bg != null && bg.computeLuminance() > 0.35) {
    ctx.warnings.add('$what: a light background washes out radar colours '
        'and night vision');
  }
  return ThemeSpec(
    key: '${ctx.addonId}/$id',
    addonId: ctx.addonId,
    name: _str(v['name']) ?? id,
    colors: colors,
    basemap: _str(v['basemap']),
  );
}

String? _palette(Object? v, int i, _Ctx ctx) {
  final rel = _str(v);
  if (rel == null || !rel.toLowerCase().endsWith('.pal')) {
    ctx.warnings.add('palette #${i + 1}: should be a path to a .pal file');
    return null;
  }
  final path = ctx.file(rel, 'palette "$rel"');
  if (path == null) return null;
  if (!File(path).existsSync()) {
    ctx.warnings.add('palette "$rel": file not found');
    return null;
  }
  return path;
}

/// Places from a CSV: `name,lat,lon[,notes]`, with or without a header.
///
/// With a header the columns may be in any order and go by name — `lat` or
/// `latitude`, `lon`/`lng`/`longitude`, `notes`/`description` — which is
/// what a spreadsheet export usually has. Rows without a readable position
/// are skipped.
List<Place> parsePlacesCsv(String text) {
  final rows = [
    for (final line in const LineSplitter().convert(text))
      if (line.trim().isNotEmpty) _csvRow(line),
  ];
  if (rows.isEmpty) return const [];
  var nameCol = 0, latCol = 1, lonCol = 2, notesCol = 3;
  var start = 0;
  final head = [for (final c in rows.first) c.trim().toLowerCase()];
  if (head.length > 1 && double.tryParse(head[1]) == null) {
    start = 1;
    int col(List<String> names, int d) {
      final i = head.indexWhere(names.contains);
      return i < 0 ? d : i;
    }

    nameCol = col(const ['name', 'title', 'label'], 0);
    latCol = col(const ['lat', 'latitude', 'y'], 1);
    lonCol = col(const ['lon', 'lng', 'long', 'longitude', 'x'], 2);
    notesCol = col(const ['notes', 'note', 'description', 'desc'], 3);
  }
  final out = <Place>[];
  for (final r in rows.skip(start)) {
    String at(int i) => i < r.length ? r[i].trim() : '';
    final lat = double.tryParse(at(latCol));
    final lon = double.tryParse(at(lonCol));
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      continue;
    }
    final notes = at(notesCol);
    out.add(Place(
      at(nameCol).isEmpty ? 'Place ${out.length + 1}' : at(nameCol),
      LatLng(lat, lon),
      notes: notes.isEmpty ? null : notes,
    ));
  }
  return out;
}

/// One CSV line, honouring double quotes (`"Smith, J."`) and doubled
/// quotes inside them.
List<String> _csvRow(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cur.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  out.add(cur.toString());
  return out;
}

/// Places from GeoJSON points, named by `name` or `title` and annotated by
/// `notes` or `description`.
List<Place> placesFromGeoJson(String text) {
  final shapes = parseGeoJson(text);
  return [
    for (final p in shapes.points)
      Place(
        p.style.label ?? 'Place',
        p.pos,
        notes: (p.properties['notes'] ?? p.properties['description'])
            ?.toString(),
      ),
  ];
}

// ------------------------------------------------------------ loading ----

class AddonLoadResult {
  const AddonLoadResult(this.addons, this.errors);
  final List<Addon> addons;

  /// Files that were not addons at all, by path, with why.
  final Map<String, String> errors;

  static const empty = AddonLoadResult([], {});
}

/// Every addon in [dir]: each `*.json` directly in it, and each sub-folder
/// holding an `addon.json`. Sorted by name, so the menus are stable.
///
/// A second addon with an id already taken is refused rather than merged:
/// two files claiming one id is almost always an old copy left beside a new
/// one, and quietly picking either would be a coin toss.
AddonLoadResult loadAddons(Directory dir) {
  if (!dir.existsSync()) return AddonLoadResult.empty;
  final addons = <Addon>[];
  final errors = <String, String>{};
  final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
  for (final e in entries) {
    final base = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (_reservedNames.contains(base) || base.startsWith('.')) continue;
    String? manifest;
    String? folder;
    if (e is File && base.toLowerCase().endsWith('.json')) {
      manifest = e.path;
    } else if (e is Directory) {
      final f = File('${e.path}/addon.json');
      if (!f.existsSync()) continue;
      manifest = f.path;
      folder = e.path;
    } else {
      continue;
    }
    try {
      final a = parseAddon(
        File(manifest).readAsStringSync(),
        path: folder ?? manifest,
        baseDir: folder ?? dir.path,
      );
      if (addons.any((x) => x.id == a.id)) {
        errors[manifest] = 'another addon already uses the id "${a.id}"';
        continue;
      }
      addons.add(a);
    } catch (e) {
      errors[manifest] = e is FormatException ? e.message : '$e';
    }
  }
  addons.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return AddonLoadResult(addons, errors);
}

/// [installed] with the addons that ship inside the app added to it.
///
/// [builtIns] is manifest text by name, as the UI layer read it from the
/// app's assets — this layer has no asset bundle to read. Built-ins are
/// single files with nothing beside them, the same as an addon installed
/// from a link, so everything they use is reached by URL or written inline.
///
/// An installed addon with a built-in's id wins: that is someone who copied
/// one out to change it, and the copy is the one they mean.
AddonLoadResult withBuiltInAddons(
  AddonLoadResult installed,
  Map<String, String> builtIns,
) {
  final addons = [...installed.addons];
  final errors = {...installed.errors};
  final names = builtIns.keys.toList()..sort();
  for (final name in names) {
    try {
      final a = parseAddon(builtIns[name]!, path: name, builtIn: true);
      if (addons.any((x) => x.id == a.id)) continue;
      addons.add(a);
    } catch (e) {
      // Only reachable by shipping a broken manifest, which a test guards
      // against; still said rather than hidden if it ever happens.
      errors['built-in $name'] = e is FormatException ? e.message : '$e';
    }
  }
  addons.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return AddonLoadResult(addons, errors);
}

/// Where each shared site id is defined more than once across [addons], as
/// warnings to show. The first addon (by name) keeps the id.
List<String> siteCollisions(List<Addon> addons) {
  final owner = <String, String>{};
  final out = <String>[];
  for (final a in addons) {
    for (final s in a.sites) {
      final first = owner[s.icao];
      if (first != null && first != a.id) {
        out.add('site ${s.icao} in "${a.id}" is ignored — "$first" '
            'already defines it');
      } else {
        owner[s.icao] = a.id;
      }
    }
  }
  return out;
}

// ---------------------------------------------------- install / remove ----

/// Download an addon manifest from [url] into [dir].
///
/// Parsed before anything is written, so a link to the wrong thing fails
/// here with a reason instead of leaving a broken file in the folder. Saved
/// as `<id>.json`; installing the same addon again replaces it, which is how
/// an update is done.
///
/// A single file has no folder to keep companion files in, so a
/// web-installed addon has to reach everything by URL.
Future<Addon> installAddonFromUrl(
  String url,
  Directory dir, {
  http.Client? client,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    throw const FormatException('that is not an http(s) link');
  }
  final c = client ?? http.Client();
  final String text;
  try {
    final resp = await c
        .get(uri, headers: userAgentHeader)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('download failed: HTTP ${resp.statusCode}');
    }
    if (resp.bodyBytes.length > 5 * 1024 * 1024) {
      throw const FormatException('too big for an addon manifest (over 5 MB)');
    }
    text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  } finally {
    if (client == null) c.close();
  }
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('${dir.path}/${_peekId(text)}.json');
  final addon = parseAddon(text, path: file.path);
  final folder = Directory('${dir.path}/${addon.id}');
  if (folder.existsSync()) {
    throw FormatException('a folder addon "${addon.id}" is already '
        'installed; remove it first');
  }
  file.writeAsStringSync(text);
  return addon;
}

/// The id, for naming the file, before the full parse runs. The parse that
/// follows is what validates it.
String _peekId(String text) {
  try {
    final id = (jsonDecode(text) as Map)['id'];
    if (id is String && _idRe.hasMatch(id)) return id;
  } catch (_) {}
  throw const FormatException('no usable "id" in that file');
}

/// Delete an addon's file, or its folder for a folder addon.
void removeAddon(Addon a) {
  if (a.builtIn) {
    throw StateError('"${a.name}" comes with the app — switch it off instead');
  }
  final t = FileSystemEntity.typeSync(a.path);
  if (t == FileSystemEntityType.directory) {
    Directory(a.path).deleteSync(recursive: true);
  } else if (t == FileSystemEntityType.file) {
    File(a.path).deleteSync();
  }
}

// ----------------------------------------------------------- settings ----

/// What the user has done with their addons: which are switched off, which
/// theme is in use, and which layers they turned on or off. Kept apart from
/// the addons so removing and reinstalling one keeps its choices.
class AddonSettings {
  AddonSettings({
    Set<String>? disabled,
    Set<String>? enabled,
    this.theme,
    Map<String, bool>? layers,
  })  : disabled = disabled ?? {},
        enabled = enabled ?? {},
        layers = layers ?? {};

  /// Addons switched off that would otherwise be on.
  final Set<String> disabled;

  /// Addons switched on that start off (`"enabled": false`, which is every
  /// built-in). Kept apart from [disabled] so that a later version shipping
  /// an addon on or off by default does not flip anyone's own choice.
  final Set<String> enabled;

  bool isEnabled(Addon a) => a.enabledByDefault
      ? !disabled.contains(a.id)
      : enabled.contains(a.id);

  void setEnabled(Addon a, bool on) {
    if (on) {
      disabled.remove(a.id);
      enabled.add(a.id);
    } else {
      enabled.remove(a.id);
      disabled.add(a.id);
    }
  }

  /// The active theme's key, or null for the built-in look.
  String? theme;

  /// Layer key to on/off, for layers the user has toggled. A layer not in
  /// here uses its own `visible` default.
  final Map<String, bool> layers;

  factory AddonSettings.fromJson(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      return AddonSettings(
        disabled: {...(m['disabled'] as List? ?? const []).whereType<String>()},
        enabled: {...(m['enabled'] as List? ?? const []).whereType<String>()},
        theme: m['theme'] as String?,
        layers: {
          for (final e in (m['layers'] as Map? ?? const {}).entries)
            if (e.key is String && e.value is bool)
              e.key as String: e.value as bool,
        },
      );
    } catch (_) {
      // A damaged settings file costs the user their toggles, not the app.
      return AddonSettings();
    }
  }

  String toJson() => const JsonEncoder.withIndent('  ').convert({
        'disabled': disabled.toList()..sort(),
        'enabled': enabled.toList()..sort(),
        'theme': theme,
        'layers': layers,
      });

  static AddonSettings load(File f) {
    try {
      return f.existsSync()
          ? AddonSettings.fromJson(f.readAsStringSync())
          : AddonSettings();
    } catch (_) {
      return AddonSettings();
    }
  }

  void save(File f) {
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(toJson());
    } catch (_) {
      // Read-only config dir: the choices last for this session only.
    }
  }
}
