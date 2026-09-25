/// Where a radar site's data comes from.
///
/// Every built-in site reads the Unidata NEXRAD buckets. An addon can add a
/// site of its own — a university radar, a club's mirror, a network nobody
/// has put on AWS — or point an existing site somewhere else, and this is
/// the layer that decides which bucket a pane's listing and download go to.
///
/// The bytes still have to be something the engine decodes: an Archive II
/// volume for Level 2, a NIDS product for Level 3. A source changes where the
/// file is, not what it is. Nothing here decodes, the same as every other
/// fetcher (docs/data-sources.md).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'identity.dart';
import 'level2_fetcher.dart';
import 'level3_fetcher.dart';
import 'nexrad_sites.g.dart';

/// How a source lists its files.
enum SourceKind {
  /// An S3-compatible bucket, listed with `?list-type=2&prefix=…` — the same
  /// protocol the NOAA buckets use, and what MinIO, R2, Wasabi and most
  /// object stores answer to.
  s3,

  /// Any URL that returns a list of files: a JSON array, a plain text file
  /// with one name per line, or a web server's directory listing. The
  /// lowest bar there is for someone with their own data — a folder behind
  /// nginx with `autoindex on` is enough.
  listing,
}

/// One place a site's Level 2 or Level 3 files live.
///
/// [url] and [prefix] are templates. `{site}` is the site id, `{site3}` the
/// three-letter id NOAA's Level 3 keys use, `{product}` the Level 3 code
/// (`N0B`, `N0G`, …), and `{yyyy}` `{MM}` `{dd}` the UTC date. A template with
/// a date in it is listed one day at a time, walking back up to [days] days,
/// which is what keeps a busy bucket's listing to one day's worth of keys.
class DataSource {
  const DataSource({
    required this.kind,
    required this.url,
    this.prefix = '',
    this.match,
    this.headers = const {},
    this.days = 2,
    this.attribution,
  });

  final SourceKind kind;
  final String url;

  /// S3 key prefix template. Unused by [SourceKind.listing].
  final String prefix;

  /// Only entries this matches are frames. Without it everything the listing
  /// returns is taken, bar the obvious non-files (`../`, sort links).
  final RegExp? match;

  /// Sent with every listing and download — an API key, a bearer token.
  /// Kept in the addon file on the device and sent to [url]'s host only: a
  /// listing may name files on another host, and those get no headers.
  final Map<String, String> headers;

  final int days;

  /// Credit the data's owner asked for. Shown on the map while a pane is on
  /// this site, the same as the basemap's.
  final String? attribution;

  bool get _dated => _hasDate(url) || _hasDate(prefix);

  static bool _hasDate(String t) =>
      t.contains('{yyyy}') || t.contains('{MM}') || t.contains('{dd}');
}

/// A radar site an addon defined.
///
/// A [NexradSite] so every place that takes a site — the panes, the picker,
/// the map's dots, the nearest-site search — takes this one unchanged.
class AddonSite extends NexradSite {
  const AddonSite(
    super.icao,
    super.name,
    super.state,
    super.lat,
    super.lon,
    super.elevFt,
    super.isTdwr, {
    required this.addonId,
    this.level2,
    this.level3,
    this.attribution,
    this.overridesBuiltIn = false,
    this.shortIdOverride,
  });

  /// Which addon this came from, for the addon manager and for errors.
  final String addonId;

  final DataSource? level2;
  final DataSource? level3;
  final String? attribution;

  /// Whether this re-defines a site the app already knows (an addon pointing
  /// KTLX at a mirror, say).
  ///
  /// Decides what happens to the level the addon did not give a source for.
  /// A real NEXRAD id falls back to NOAA's bucket for it. A new id does not:
  /// NOAA's Level 3 keys use only the last three letters, so a private radar
  /// called `XTLX` would otherwise be shown KTLX's data under its own name,
  /// with nothing on screen to say it was someone else's radar.
  final bool overridesBuiltIn;

  /// The id Level 3 file names use, where it is not simply the last three
  /// letters of [icao].
  final String? shortIdOverride;

  @override
  String get shortId => shortIdOverride ?? super.shortId;
}

/// Raised when a site has no source for the level asked of it. Its message
/// is what the pane shows, so it says what to do about it.
class NoSourceException implements Exception {
  NoSourceException(this.site, this.level);
  final AddonSite site;
  final String level;

  @override
  String toString() => '${site.icao} (from addon "${site.addonId}") has no '
      '$level source — pick a Level ${level == 'Level 2' ? '3' : '2'} product '
      'or add a "${level == 'Level 2' ? 'level2' : 'level3'}" source to the '
      'addon';
}

/// The built-in radar list with an addon's sites laid over it.
///
/// An addon site with a built-in id replaces the built-in one, so a mirror
/// can stand in for a site rather than sitting beside it as a duplicate dot.
/// Where two addons define the same new id, the first wins; the addon loader
/// reports the collision.
List<NexradSite> mergeSites(Iterable<AddonSite> extra) {
  final byId = <String, NexradSite>{};
  for (final s in nexradSites) {
    // TDWR products are a later phase; offering one opens on a radar the app
    // cannot draw.
    if (!s.isTdwr) byId[s.icao] = s;
  }
  final seen = <String>{};
  for (final s in extra) {
    if (!seen.add(s.icao)) continue;
    byId[s.icao] = s;
  }
  return byId.values.toList();
}

// ----------------------------------------------------------- dispatch ----

/// Recent Level 3 keys for [site], newest last — from the addon's source if
/// it has one, NOAA's bucket otherwise.
Future<List<String>> listSiteLevel3(
  NexradSite site,
  String product, {
  int count = 10,
  DateTime? before,
  http.Client? client,
}) {
  if (site is AddonSite) {
    final src = site.level3;
    if (src != null) {
      return listSource(
        src,
        site: site,
        product: product,
        count: count,
        before: before,
        client: client,
      );
    }
    if (!site.overridesBuiltIn) {
      return Future.error(NoSourceException(site, 'Level 3'));
    }
  }
  return listRecentKeys(site.shortId, product, count: count, before: before);
}

/// One Level 3 file for [site], by a key [listSiteLevel3] returned.
Future<Uint8List> fetchSiteLevel3(
  NexradSite site,
  String key, {
  http.Client? client,
}) async {
  if (site is AddonSite && site.level3 != null) {
    return fetchSourceObject(site.level3!, key, client: client);
  }
  return Uint8List.fromList(await fetchObject(key));
}

/// Recent Level 2 volume keys for [site], newest last.
Future<List<String>> listSiteLevel2(
  NexradSite site, {
  int count = 3,
  DateTime? before,
  http.Client? client,
}) {
  if (site is AddonSite) {
    final src = site.level2;
    if (src != null) {
      return listSource(
        src,
        site: site,
        count: count,
        before: before,
        client: client,
      );
    }
    if (!site.overridesBuiltIn) {
      return Future.error(NoSourceException(site, 'Level 2'));
    }
  }
  return listRecentVolumes(site.icao, count: count, before: before);
}

/// One Level 2 volume for [site], by a key [listSiteLevel2] returned.
Future<Uint8List> fetchSiteLevel2(
  NexradSite site,
  String key, {
  http.Client? client,
}) {
  if (site is AddonSite && site.level2 != null) {
    return fetchSourceObject(site.level2!, key, client: client);
  }
  return fetchVolume(key);
}

// ------------------------------------------------------------ sources ----

/// Fill in a source template for one site, product and day.
String expandTemplate(
  String template, {
  required NexradSite site,
  String product = '',
  DateTime? day,
}) {
  String p(int v) => v.toString().padLeft(2, '0');
  var out = template
      .replaceAll('{site}', site.icao)
      .replaceAll('{site3}', site.shortId)
      .replaceAll('{product}', product);
  if (day != null) {
    out = out
        .replaceAll('{yyyy}', '${day.year}')
        .replaceAll('{MM}', p(day.month))
        .replaceAll('{dd}', p(day.day));
  }
  return out;
}

/// A file a listing found, with the time it is for if that could be told.
class SourceEntry {
  const SourceEntry(this.url, this.time);
  final String url;
  final DateTime? time;
}

/// List [src] for one site (and, for Level 3, one product): the newest
/// [count] file URLs, oldest first, at or before [before] when replaying.
///
/// The keys this returns are full URLs, so [fetchSourceObject] needs nothing
/// but the key to fetch one.
Future<List<String>> listSource(
  DataSource src, {
  required NexradSite site,
  String product = '',
  int count = 10,
  DateTime? before,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final now = (before ?? DateTime.now()).toUtc();
    final days = src._dated ? src.days.clamp(1, 14) : 1;
    final found = <SourceEntry>[];
    for (var back = 0; back < days; back++) {
      final day = now.subtract(Duration(days: back));
      final entries = switch (src.kind) {
        SourceKind.s3 => await _listS3(c, src, site, product, day),
        SourceKind.listing => await _listIndex(c, src, site, product, day),
      };
      found.insertAll(0, entries);
      if (_usable(found, before).length >= count) break;
    }
    final usable = _usable(found, before);
    final seen = <String>{};
    final unique = [
      for (final e in usable)
        if (seen.add(e.url)) e,
    ];
    // Time order where every entry has one. Where some do not, name order:
    // most radar filenames carry a fixed-width stamp, which sorts the same.
    if (unique.every((e) => e.time != null)) {
      unique.sort((a, b) => a.time!.compareTo(b.time!));
    } else {
      unique.sort((a, b) => a.url.compareTo(b.url));
    }
    final urls = [for (final e in unique) e.url];
    return urls.length > count ? urls.sublist(urls.length - count) : urls;
  } finally {
    if (client == null) c.close();
  }
}

/// During replay only files known to be from before the replay time are
/// usable — a file with no readable time could be from any moment, and
/// showing it as "the past" would be making that up.
List<SourceEntry> _usable(List<SourceEntry> all, DateTime? before) {
  if (before == null) return all;
  final cut = before.toUtc();
  return [
    for (final e in all)
      if (e.time != null && !e.time!.isAfter(cut)) e,
  ];
}

final _keyRe = RegExp(r'<Key>([^<]+)</Key>');
final _tokenRe = RegExp(r'<NextContinuationToken>([^<]+)</NextContinuationToken>');

Future<List<SourceEntry>> _listS3(
  http.Client c,
  DataSource src,
  NexradSite site,
  String product,
  DateTime day,
) async {
  final base = _trimSlash(expandTemplate(src.url, site: site, day: day));
  final prefix =
      expandTemplate(src.prefix, site: site, product: product, day: day);
  final out = <SourceEntry>[];
  String? token;
  // Pages rather than one request: a prefix without a date in it can hold
  // more than S3's thousand keys, and the newest ones are on the last page.
  for (var page = 0; page < 10; page++) {
    final q = StringBuffer('$base/?list-type=2&max-keys=1000'
        '&prefix=${Uri.encodeQueryComponent(prefix)}');
    if (token != null) {
      q.write('&continuation-token=${Uri.encodeQueryComponent(token)}');
    }
    final resp = await c
        .get(Uri.parse(q.toString()), headers: _headersFor(src))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      // Nothing for this day is an ordinary answer (a quiet radar); anything
      // else on the first page is worth saying.
      if (page == 0 && resp.statusCode != 404) {
        throw Exception('listing $base failed: HTTP ${resp.statusCode}');
      }
      break;
    }
    for (final m in _keyRe.allMatches(resp.body)) {
      final key = _xmlUnescape(m.group(1)!);
      if (src.match != null && !src.match!.hasMatch(key)) continue;
      final path = key.split('/').map(Uri.encodeComponent).join('/');
      out.add(SourceEntry('$base/$path', entryTime(key)));
    }
    token = _tokenRe.firstMatch(resp.body)?.group(1);
    if (token == null) break;
    token = _xmlUnescape(token);
  }
  return out;
}

Future<List<SourceEntry>> _listIndex(
  http.Client c,
  DataSource src,
  NexradSite site,
  String product,
  DateTime day,
) async {
  final url = expandTemplate(src.url, site: site, product: product, day: day);
  final resp = await c
      .get(Uri.parse(url), headers: _headersFor(src))
      .timeout(const Duration(seconds: 20));
  if (resp.statusCode == 404) return const [];
  if (resp.statusCode != 200) {
    throw Exception('listing $url failed: HTTP ${resp.statusCode}');
  }
  return parseIndex(resp.body, Uri.parse(url), match: src.match);
}

/// Read a file list in any of the shapes [SourceKind.listing] accepts.
///
/// JSON: an array of names or of objects (`url`/`href`/`key`/`name`/`file`,
/// with an optional `time`), or an object holding one under `files`,
/// `items` or `entries`. HTML: every `href`. Anything else: one name per
/// line. Relative names are resolved against [base], the listing's own URL.
List<SourceEntry> parseIndex(String body, Uri base, {RegExp? match}) {
  final raw = <(String, DateTime?)>[];
  final trimmed = body.trimLeft();
  Object? json;
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      json = jsonDecode(trimmed);
    } catch (_) {
      json = null;
    }
  }
  if (json is Map) {
    json = json['files'] ?? json['items'] ?? json['entries'];
  }
  if (json is List) {
    for (final item in json) {
      if (item is String) {
        raw.add((item, null));
      } else if (item is Map) {
        final name = item['url'] ?? item['href'] ?? item['key'] ??
            item['name'] ?? item['file'];
        if (name is String) raw.add((name, _readTime(item['time'])));
      }
    }
  } else if (body.contains('<a ') || body.contains('<A ')) {
    for (final m in RegExp('href\\s*=\\s*["\']([^"\']+)["\']',
            caseSensitive: false)
        .allMatches(body)) {
      raw.add((_htmlUnescape(m.group(1)!), null));
    }
  } else {
    for (final line in const LineSplitter().convert(body)) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      raw.add((t, null));
    }
  }

  final out = <SourceEntry>[];
  for (final (name, time) in raw) {
    // Directory listings carry links that are not files: the parent, the
    // column-sort links, sub-folders.
    if (name.endsWith('/') ||
        name.startsWith('?') ||
        name.startsWith('#') ||
        name.startsWith('mailto:') ||
        name.startsWith('javascript:')) {
      continue;
    }
    if (match != null && !match.hasMatch(name)) continue;
    final url = base.resolve(name).toString();
    out.add(SourceEntry(url, time ?? entryTime(name)));
  }
  return out;
}

/// The scan time a file name carries, if it carries one.
///
/// Radar files almost always embed a UTC stamp, in one of a few shapes:
/// `KTLX20260728_053715_V06`, `TLX_N0B_2026_07_28_05_09_07`,
/// `…-20260728-053715.gz`, `2026-07-28T05:37:15Z`. Read from the last path
/// segment first, so a dated folder does not stand in for the file's time.
DateTime? entryTime(String name) {
  final last = name.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
  return _stamp(last) ?? _stamp(name);
}

final _stampRe = RegExp(
  r'(?<!\d)((?:19|20)\d\d)[-_]?(\d\d)[-_]?(\d\d)[-_T ]?(\d\d)[-_:]?(\d\d)'
  r'(?:[-_:]?(\d\d))?(?!\d)',
);

DateTime? _stamp(String s) {
  for (final m in _stampRe.allMatches(s)) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final h = int.parse(m.group(4)!);
    final mi = int.parse(m.group(5)!);
    final se = int.tryParse(m.group(6) ?? '') ?? 0;
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 59) {
      continue;
    }
    return DateTime.utc(y, mo, d, h, mi, se);
  }
  return null;
}

DateTime? _readTime(Object? v) {
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (v * 1000).round(),
      isUtc: true,
    );
  }
  if (v is String) return DateTime.tryParse(v)?.toUtc();
  return null;
}

/// Download one file a source listed.
Future<Uint8List> fetchSourceObject(
  DataSource src,
  String url, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final uri = Uri.parse(url);
    final resp = await c
        .get(
          uri,
          headers: _sameHost(src, uri) ? _headersFor(src) : userAgentHeader,
        )
        // Longer than a listing: a Level 2 volume is 5-15 MB, and that is
        // tens of seconds on a weak phone connection.
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) {
      throw Exception('GET $url failed: HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  } finally {
    if (client == null) c.close();
  }
}

/// Ours first, so an addon can override the User-Agent if its server needs
/// something particular, but says who we are by default.
Map<String, String> _headersFor(DataSource src) =>
    {...userAgentHeader, ...src.headers};

/// Whether [uri] is on the host the source itself names. An index is free to
/// list absolute URLs anywhere; a token meant for the addon's server must not
/// follow them there.
bool _sameHost(DataSource src, Uri uri) {
  final own = Uri.tryParse(src.url.replaceAll(RegExp(r'\{[^}]*\}'), 'x'));
  return own != null && own.host.toLowerCase() == uri.host.toLowerCase();
}

String _trimSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

String _xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _htmlUnescape(String s) => _xmlUnescape(s.replaceAll('&#39;', "'"));
