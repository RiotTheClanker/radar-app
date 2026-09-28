/// Addon manifests: what loads, what is skipped with a warning, and what is
/// refused outright.
///
/// The loader's promise is that one mistake in someone's file costs that one
/// item, not the addon — and that nothing in a file can reach outside its
/// own folder. Both are easy to break without noticing, so both are pinned.
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_app/data/addons.dart';
import 'package:radar_app/data/nexrad_sites.g.dart';
import 'package:radar_app/data/radar_source.dart';
import 'package:radar_app/ui/wx_theme.dart';

const _full = '''
{
  "id": "okc-club",
  "name": "OKC spotter pack",
  "version": "1.2",
  "author": "Club",
  "description": "Our radar, our roads, our shelters.",
  "sites": [
    {"id": "xokc", "name": "Club radar", "state": "OK",
     "lat": 35.4, "lon": -97.6, "elevFt": 1200,
     "attribution": "Radar © OKC Club",
     "level2": {"type": "s3", "url": "https://club.example.org",
                "prefix": "{yyyy}/{MM}/{dd}/{site}/"},
     "level3": {"type": "index",
                "url": "https://club.example.org/l3/{site3}/{product}/"}},
    {"id": "KTLX", "lat": 35.333, "lon": -97.278,
     "level2": {"type": "index", "url": "https://mirror.example.org/KTLX/"}}
  ],
  "overlays": [
    {"id": "roads", "name": "County roads", "type": "geojson",
     "url": "https://club.example.org/roads.geojson", "stroke": "#FFAA00",
     "width": 2, "above": true},
    {"id": "sat", "name": "Club tiles", "type": "tiles",
     "url": "https://tiles.example.org/{z}/{x}/{y}.png", "opacity": 0.5,
     "attribution": "Tiles © Club", "visible": false}
  ],
  "places": [
    {"id": "shelters", "name": "Shelters", "icon": "shelter",
     "color": "#6FBF73",
     "items": [{"name": "Main St", "lat": 35.5, "lon": -97.5,
                "notes": "Basement, north door"}]}
  ],
  "themes": [
    {"id": "night", "name": "Night red",
     "colors": {"bg0": "#000000", "text": "#FF3030", "accent": "#C00000"},
     "basemap": "Dark"}
  ]
}
''';

void main() {
  group('a full manifest', () {
    late Addon a;
    setUp(() => a = parseAddon(_full, path: '/x/okc.json', baseDir: '/x'));

    test('reads its identity', () {
      expect(a.id, 'okc-club');
      expect(a.name, 'OKC spotter pack');
      expect(a.version, '1.2');
      expect(a.warnings, isEmpty, reason: a.warnings.join('\n'));
    });

    test('reads a new site with both sources', () {
      final s = a.sites.first;
      expect(s.icao, 'XOKC', reason: 'ids are upper-cased');
      expect(s.shortId, 'OKC');
      expect(s.lat, 35.4);
      expect(s.addonId, 'okc-club');
      expect(s.overridesBuiltIn, isFalse);
      expect(s.level2!.kind, SourceKind.s3);
      expect(s.level2!.prefix, '{yyyy}/{MM}/{dd}/{site}/');
      expect(s.level3!.kind, SourceKind.listing);
    });

    test('a built-in id is an override and borrows the built-in name', () {
      final s = a.sites[1];
      expect(s.icao, 'KTLX');
      expect(s.overridesBuiltIn, isTrue);
      expect(s.name, 'Oklahoma City');
      expect(s.state, 'OK');
      expect(s.level3, isNull);
    });

    test('reads overlays, keyed by addon', () {
      expect(a.overlays.map((o) => o.key), ['okc-club/roads', 'okc-club/sat']);
      final roads = a.overlays.first;
      expect(roads.kind, OverlayKind.geojson);
      expect(roads.stroke, const Color(0xFFFFAA00));
      expect(roads.aboveRadar, isTrue);
      final sat = a.overlays.last;
      expect(sat.kind, OverlayKind.tiles);
      expect(sat.opacity, 0.5);
      expect(sat.visibleByDefault, isFalse);
    });

    test('reads places and themes', () {
      final g = a.places.single;
      expect(g.icon, 'shelter');
      expect(g.places.single.notes, 'Basement, north door');
      final t = a.themes.single;
      expect(t.key, 'okc-club/night');
      expect(t.colors['bg0'], const Color(0xFF000000));
      expect(t.basemap, 'Dark');
    });

    test('summarises what it adds', () {
      expect(a.summary, '2 radar sites · 2 overlays · 1 place · 1 theme');
    });
  });

  group('refused outright', () {
    test('not JSON', () {
      expect(() => parseAddon('{nope', path: 'p'), throwsFormatException);
    });
    test('no id', () {
      expect(
        () => parseAddon('{"name": "x"}', path: 'p'),
        throwsFormatException,
      );
    });
    test('an id with a path in it', () {
      expect(
        () => parseAddon('{"id": "../x", "name": "x"}', path: 'p'),
        throwsFormatException,
      );
    });
    test('no name', () {
      expect(() => parseAddon('{"id": "x"}', path: 'p'), throwsFormatException);
    });
  });

  group('skipped with a warning, the rest kept', () {
    Addon parse(String body) => parseAddon(
      '{"id": "t", "name": "T", $body}',
      path: '/x/t.json',
      baseDir: '/x',
    );

    test('a site with no position', () {
      final a = parse(
        '"sites": [{"id": "XAAA"}, '
        '{"id": "XBBB", "lat": 1, "lon": 2, '
        '"level2": {"url": "https://e.org/"}}]',
      );
      expect(a.sites.map((s) => s.icao), ['XBBB']);
      expect(a.warnings.single, contains('XAAA'));
    });

    test('a new site with no source at all', () {
      final a = parse('"sites": [{"id": "XAAA", "lat": 1, "lon": 2}]');
      expect(a.sites, hasLength(1));
      expect(a.warnings.single, contains('nowhere to get data'));
    });

    test('a level3 source that ignores the product', () {
      final a = parse(
        '"sites": [{"id": "XAAA", "lat": 1, "lon": 2, '
        '"level3": {"url": "https://e.org/all/"}}]',
      );
      expect(a.warnings.single, contains('{product}'));
    });

    test('a bad regex drops that source', () {
      final a = parse(
        '"sites": [{"id": "XAAA", "lat": 1, "lon": 2, '
        '"level2": {"url": "https://e.org/", "match": "("}}]',
      );
      expect(a.sites.single.level2, isNull);
      expect(a.warnings.join(), contains('regular expression'));
    });

    test('an overlay of an unknown type', () {
      final a = parse(
        '"overlays": [{"id": "x", "type": "kml", '
        '"url": "https://e.org/x.kml"}]',
      );
      expect(a.overlays, isEmpty);
      expect(a.warnings.single, contains('"tiles", "wms" or "geojson"'));
    });

    test('a tile layer with no {z}', () {
      final a = parse(
        '"overlays": [{"id": "x", "type": "tiles", '
        '"url": "https://e.org/tile.png"}]',
      );
      expect(a.overlays, isEmpty);
    });

    test('an unknown icon falls back to a pin', () {
      final a = parse(
        '"places": [{"icon": "unicorn", '
        '"items": [{"lat": 1, "lon": 2}]}]',
      );
      expect(a.places.single.icon, 'pin');
      expect(a.warnings.single, contains('unicorn'));
    });

    test('an unknown theme colour', () {
      final a = parse('"themes": [{"colors": {"bg0": "#000", "sky": "#fff"}}]');
      expect(a.themes.single.colors.keys, ['bg0']);
      expect(a.warnings.single, contains('sky'));
    });

    test('a light theme is allowed but called out', () {
      final a = parse('"themes": [{"colors": {"bg0": "#FFFFFF"}}]');
      expect(a.themes, hasLength(1));
      expect(a.warnings.single, contains('night vision'));
    });

    test('unknown top-level fields', () {
      final a = parse('"plugins": []');
      expect(a.warnings.single, contains('plugins'));
    });

    test('a newer format still loads', () {
      final a = parse('"format": 99');
      expect(a.warnings.single, contains('newer'));
    });
  });

  group('open-format and folder sources', () {
    Addon site(String body) => parseAddon(
      '{"id": "t", "name": "T", "sites": [{"id": "XOPN", "lat": 1, '
      '"lon": 2, $body}]}',
      path: '/x/t',
      baseDir: '/x/t',
    );

    test('an open source makes the site open-format', () {
      final a = site('"open": {"type": "folder", "path": "data/{product}"}');
      final s = a.sites.single;
      expect(s.isOpen, isTrue);
      expect(s.open!.kind, SourceKind.folder);
      expect(s.open!.url, '/x/t/data/{product}');
      expect(a.warnings, isEmpty, reason: a.warnings.join());
    });

    test(
      'folder paths may be absolute or under home, relative stays inside',
      () {
        expect(
          site(
            '"open": {"type": "folder", "path": "/srv/radar/{product}"}',
          ).sites.single.open!.url,
          '/srv/radar/{product}',
        );
        final home = Platform.environment['HOME'];
        if (home != null) {
          expect(
            site(
              '"open": {"type": "folder", "path": "~/radar/{product}"}',
            ).sites.single.open!.url,
            '$home/radar/{product}',
          );
        }
        final bad = site(
          '"open": {"type": "folder", "path": "../../{product}"}',
        );
        expect(bad.sites.single.open, isNull);
        expect(bad.warnings.join(), contains('outside the addon folder'));
      },
    );

    test('an open source without {product} is called out', () {
      final a = site('"open": {"type": "folder", "path": "/srv/all"}');
      expect(a.warnings.single, contains('{product}'));
    });

    test('open alongside level2/level3 wins, and says so', () {
      final a = site(
        '"open": {"type": "folder", "path": "/d/{product}"}, '
        '"level2": {"url": "https://e.org/"}',
      );
      expect(a.sites.single.isOpen, isTrue);
      expect(a.warnings.single, contains('ignored'));
    });

    test('a folder source with no path', () {
      final a = site('"open": {"type": "folder"}');
      expect(a.sites.single.open, isNull);
      expect(a.warnings.join(), contains('"path"'));
    });
  });

  group('files stay inside the addon folder', () {
    Addon withFile(String rel) => parseAddon(
      '{"id": "t", "name": "T", "overlays": [{"id": "o", '
      '"type": "geojson", "file": "$rel"}]}',
      path: '/x/t',
      baseDir: '/x/t',
    );

    test('a relative file resolves into the folder', () {
      expect(
        withFile('roads.geojson').overlays.single.file,
        '/x/t/roads.geojson',
      );
      expect(
        withFile('data/roads.geojson').overlays.single.file,
        '/x/t/data/roads.geojson',
      );
    });

    for (final bad in [
      '../../.ssh/id_rsa',
      'data/../../secret',
      '/etc/passwd',
      r'C:\\Windows\\win.ini',
    ]) {
      test('refuses $bad', () {
        final a = withFile(bad);
        expect(a.overlays, isEmpty);
        expect(a.warnings.join(), contains('outside the addon folder'));
      });
    }

    test('a web-installed addon cannot use files at all', () {
      final a = parseAddon(
        '{"id": "t", "name": "T", "overlays": [{"id": "o", '
        '"type": "geojson", "file": "x.geojson"}]}',
        path: 't.json',
      );
      expect(a.overlays, isEmpty);
      expect(a.warnings.join(), contains('"url"'));
    });
  });

  group('places from files', () {
    test('CSV without a header', () {
      final p = parsePlacesCsv(
        'Home,35.1,-97.2\n"Smith, J.",35.2,-97.3,"a ""b"""',
      );
      expect(p.map((x) => x.name), ['Home', 'Smith, J.']);
      expect(p.last.notes, 'a "b"');
      expect(p.first.pos.latitude, 35.1);
    });

    test('CSV with a header in its own order', () {
      final p = parsePlacesCsv(
        'Longitude,Latitude,Title,Description\n-97.2,35.1,Home,Front door\n'
        'bad,row,,\n',
      );
      expect(p, hasLength(1));
      expect(p.single.name, 'Home');
      expect(p.single.notes, 'Front door');
      expect(p.single.pos.longitude, -97.2);
    });

    test('GeoJSON points', () {
      final p = placesFromGeoJson(
        '{"type": "FeatureCollection", "features": ['
        '{"type": "Feature", "properties": {"name": "A", "description": "d"},'
        ' "geometry": {"type": "Point", "coordinates": [-97, 35]}}]}',
      );
      expect(p.single.name, 'A');
      expect(p.single.notes, 'd');
      expect(p.single.pos.latitude, 35);
    });
  });

  group('the addons folder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('addons_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads single files and folders, and reports the rest', () {
      File(
        '${dir.path}/b.json',
      ).writeAsStringSync('{"id": "b", "name": "Bravo"}');
      final folder = Directory('${dir.path}/alpha')..createSync();
      File('${folder.path}/addon.json').writeAsStringSync(
        '{"id": "a", "name": "Alpha", "places": [{"file": "p.csv"}]}',
      );
      File('${folder.path}/p.csv').writeAsStringSync('X,1,2\n');
      File('${dir.path}/broken.json').writeAsStringSync('{');
      File(
        '${dir.path}/dupe.json',
      ).writeAsStringSync('{"id": "b", "name": "Again"}');
      File('${dir.path}/README.txt').writeAsStringSync('hi');

      final r = loadAddons(dir);
      expect(r.addons.map((a) => a.name), [
        'Alpha',
        'Bravo',
      ], reason: 'sorted by name');
      expect(
        r.addons.first.places.single.places.single.name,
        'X',
        reason: 'files resolve inside the folder',
      );
      expect(
        r.addons.first.path,
        folder.path,
        reason: 'removing a folder addon removes the folder',
      );
      expect(
        r.errors.keys.map((k) => k.split('/').last),
        unorderedEquals(['broken.json', 'dupe.json']),
      );
    });

    test('a missing folder is no addons, not an error', () {
      final r = loadAddons(Directory('${dir.path}/nope'));
      expect(r.addons, isEmpty);
      expect(r.errors, isEmpty);
    });

    test('installing from a link validates, then saves as <id>.json', () async {
      final client = MockClient(
        (req) async => http.Response('{"id": "web", "name": "Web pack"}', 200),
      );
      final a = await installAddonFromUrl(
        'https://e.org/pack.json',
        dir,
        client: client,
      );
      expect(a.id, 'web');
      expect(File('${dir.path}/web.json').existsSync(), isTrue);
      expect(loadAddons(dir).addons.single.id, 'web');

      removeAddon(loadAddons(dir).addons.single);
      expect(File('${dir.path}/web.json').existsSync(), isFalse);
    });

    test('installing something that is not an addon writes nothing', () async {
      final client = MockClient((req) async => http.Response('<html>', 200));
      await expectLater(
        installAddonFromUrl('https://e.org/x', dir, client: client),
        throwsFormatException,
      );
      expect(dir.listSync(), isEmpty);
    });

    test('settings survive a round trip, and a damaged file resets', () {
      final f = File('${dir.path}/s.json');
      final s = AddonSettings(
        disabled: {'a'},
        theme: 'a/t',
        layers: {'a/o': false},
      );
      s.save(f);
      final back = AddonSettings.load(f);
      expect(back.disabled, {'a'});
      expect(back.theme, 'a/t');
      expect(back.layers, {'a/o': false});

      f.writeAsStringSync('{broken');
      expect(AddonSettings.load(f).disabled, isEmpty);
    });
  });

  group('sites across addons', () {
    Addon withSite(String id, String site) => parseAddon(
      '{"id": "$id", "name": "$id", "sites": [{"id": "$site", '
      '"lat": 1, "lon": 2, "level2": {"url": "https://e.org/"}}]}',
      path: id,
    );

    test('an override replaces the built-in rather than duplicating it', () {
      final merged = mergeSites(withSite('m', 'KTLX').sites);
      final tlx = merged.where((s) => s.icao == 'KTLX').toList();
      expect(tlx, hasLength(1));
      expect(tlx.single, isA<AddonSite>());
    });

    test('a new site is added; built-in TDWR stays out', () {
      final merged = mergeSites(withSite('m', 'XNEW').sites);
      expect(merged.any((s) => s.icao == 'XNEW'), isTrue);
      expect(merged.any((s) => s.isTdwr), isFalse);
    });

    test('a TDWR an addon defines is in', () {
      final merged = mergeSites(withSite('m', 'TOKC').sites);
      final t = merged.singleWhere((s) => s.icao == 'TOKC');
      expect(t, isA<AddonSite>());
      expect(t.isTdwr, isTrue);
    });

    test('two addons claiming one id: the first keeps it, and it is said', () {
      final a = withSite('a', 'XNEW'), b = withSite('b', 'XNEW');
      final merged = mergeSites([...a.sites, ...b.sites]);
      final x = merged.singleWhere((s) => s.icao == 'XNEW') as AddonSite;
      expect(x.addonId, 'a');
      expect(siteCollisions([a, b]).single, contains('"a" already'));
    });
  });

  test('every documented example loads without a warning', () {
    // docs/addons/examples is what people copy from. An example that has
    // drifted from the parser teaches the wrong format.
    final r = loadAddons(Directory('../docs/addons/examples'));
    expect(r.errors, isEmpty);
    expect(
      r.addons.map((a) => a.id),
      unorderedEquals([
        'night-red',
        'example-spotters',
        'example-radar',
        'test-addon',
        'example-open-radar',
      ]),
    );
    for (final a in r.addons) {
      expect(a.warnings, isEmpty, reason: '${a.id}: ${a.warnings}');
    }
    final pack = r.addons.firstWhere((a) => a.id == 'example-spotters');
    expect(pack.places.first.places, hasLength(2), reason: 'from the CSV');
  });

  group('radars that name their products differently', () {
    const tdwr = '''
{"id": "td", "name": "TD", "sites": [{"id": "TOKC", "lat": 35.27,
 "lon": -97.51, "products": {"n0b": "tz0", "N0G": "TV0"},
 "level3": {"type": "s3", "url": "https://bucket.example.org",
            "prefix": "{site3}_{product}_{yyyy}_{MM}_{dd}"}}]}
''';
    late AddonSite s;
    setUp(() => s = parseAddon(tdwr, path: 'td').sites.single);

    test('a TDWR id stays a TDWR, and does not fall back to NOAA Level 2', () {
      expect(s.isTdwr, isTrue);
      expect(s.name, 'Norman Wfo', reason: 'borrowed from the built-in');
      expect(s.overridesBuiltIn, isFalse);
      expect(isSelectableSite(s), isTrue);
      expect(
        isSelectableSite(nexradSites.firstWhere((x) => x.icao == 'TOKC')),
        isFalse,
        reason: 'the built-in TDWR entry has no source to read',
      );
    });

    test('codes are mapped, and an unmapped one is not a product', () {
      expect(s.level3Code('N0B'), 'TZ0');
      expect(s.level3Code('N0G'), 'TV0');
      expect(s.level3Code('N0C'), isNull);
    });

    test('the listing asks for the radar\'s own code', () async {
      final asked = <Uri>[];
      final client = MockClient((req) async {
        asked.add(req.url);
        return http.Response(
          '<ListBucketResult><Key>OKC_TZ0_2026_09_28_12_00_03</Key>'
          '</ListBucketResult>',
          200,
        );
      });
      final keys = await listSiteLevel3(s, 'N0B', count: 1, client: client);
      expect(keys.single, endsWith('/OKC_TZ0_2026_09_28_12_00_03'));
      expect(asked.first.queryParameters['prefix'], startsWith('OKC_TZ0_'));
    });

    test('an unmapped product and Level 2 fail with a reason', () async {
      await expectLater(
        listSiteLevel3(s, 'N0C'),
        throwsA(isA<NoProductException>()),
      );
      await expectLater(
        listSiteLevel2(s),
        throwsA(
          isA<NoSourceException>().having(
            (e) => '$e',
            'message',
            contains('TDWR'),
          ),
        ),
      );
    });

    test('a site with no map passes codes through', () {
      final a = parseAddon(_full, path: 'x');
      expect(a.sites.first.level3Code('N0B'), 'N0B');
    });
  });

  group('wms overlays and bounds', () {
    Addon ov(String body) => parseAddon(
      '{"id": "t", "name": "T", "overlays": [{"id": "o", $body}]}',
      path: 't',
    );

    test('reads a WMS layer', () {
      final a = ov(
        '"type": "wms", "url": "https://geo.example.org/wms?dataset=R", '
        '"layers": "A, B", "styles": ["s"], "params": {"TIME": "now", "n": 2}, '
        '"bounds": [40, -145, 72, -50], "refreshMinutes": 5',
      );
      expect(a.warnings, isEmpty, reason: a.warnings.join());
      final o = a.overlays.single;
      expect(o.kind, OverlayKind.wms);
      expect(o.wms!.layers, ['A', 'B']);
      expect(o.wms!.styles, ['s']);
      expect(o.wms!.version, '1.3.0');
      expect(o.wms!.transparent, isTrue);
      expect(o.wms!.params, {'TIME': 'now', 'n': '2'});
      expect(o.bounds, (south: 40.0, west: -145.0, north: 72.0, east: -50.0));
    });

    test('reads a simplify distance, capped', () {
      final a = ov(
        '"type": "geojson", "url": "https://e.org/f.json", "simplify": 150',
      );
      expect(a.overlays.single.simplifyMeters, 150);
      expect(
        ov('"type": "geojson", "url": "https://e.org/f.json", '
                '"simplify": 1e9')
            .overlays
            .single
            .simplifyMeters,
        50000,
      );
    });

    test('a WMS layer needs its layer names', () {
      final a = ov('"type": "wms", "url": "https://geo.example.org/wms"');
      expect(a.overlays, isEmpty);
      expect(a.warnings.single, contains('"layers"'));
    });

    test('bad bounds are dropped, the layer kept', () {
      final a = ov(
        '"type": "tiles", "url": "https://t.example.org/{z}/{x}/{y}.png", '
        '"bounds": [72, 0, 40, 10]',
      );
      expect(a.overlays.single.bounds, isNull);
      expect(a.warnings.single, contains('bounds'));
    });

    test('a refreshing tile URL changes once per interval', () {
      final o = ov(
        '"type": "tiles", "url": "https://t.example.org/{z}/{x}/{y}.png", '
        '"refreshMinutes": 5',
      ).overlays.single;
      final t0 = DateTime.utc(2026, 9, 28, 12, 0, 30);
      expect(o.tileUrlAt(t0), o.tileUrlAt(t0.add(const Duration(minutes: 4))));
      expect(
        o.tileUrlAt(t0),
        isNot(o.tileUrlAt(t0.add(const Duration(minutes: 5)))),
      );
      expect(o.tileUrlAt(t0), startsWith('https://t.example.org/{z}/{x}/{y}.png?_='));
      final still = ov(
        '"type": "tiles", "url": "https://t.example.org/{z}/{x}/{y}.png"',
      ).overlays.single;
      expect(still.tileUrlAt(t0), 'https://t.example.org/{z}/{x}/{y}.png');
    });
  });

  group('addons that ship off, and ones built in', () {
    const optIn = '{"id": "o", "name": "Opt in", "enabled": false}';
    const plain = '{"id": "p", "name": "Plain"}';

    test('"enabled": false starts off until switched on', () {
      final o = parseAddon(optIn, path: 'o');
      final p = parseAddon(plain, path: 'p');
      expect(o.warnings, isEmpty);
      final s = AddonSettings();
      expect(s.isEnabled(o), isFalse);
      expect(s.isEnabled(p), isTrue);
      s.setEnabled(o, true);
      s.setEnabled(p, false);
      expect(s.isEnabled(o), isTrue);
      expect(s.isEnabled(p), isFalse);
      s.setEnabled(o, false);
      expect(s.isEnabled(o), isFalse);
    });

    test('the opt-in choice survives a round trip', () {
      final dir = Directory.systemTemp.createTempSync('addon_settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/s.json');
      (AddonSettings()..setEnabled(parseAddon(optIn, path: 'o'), true)).save(f);
      expect(AddonSettings.load(f).enabled, {'o'});
    });

    test('built-ins join the installed ones, and an installed copy wins', () {
      final installed = AddonLoadResult(
        [parseAddon('{"id": "b", "name": "Mine"}', path: '/x/b.json')],
        const {},
      );
      final r = withBuiltInAddons(installed, {
        'b.json': '{"id": "b", "name": "Shipped B"}',
        'c.json': '{"id": "c", "name": "Shipped C"}',
        'bad.json': '{',
      });
      expect(r.addons.map((a) => a.name), ['Mine', 'Shipped C']);
      expect(r.addons.last.builtIn, isTrue);
      expect(r.addons.first.builtIn, isFalse);
      expect(r.errors.keys, ['built-in bad.json']);
      expect(() => removeAddon(r.addons.last), throwsStateError);
    });
  });

  test('every built-in addon loads cleanly and ships switched off', () {
    // assets/addons is inside the app. A warning there is a broken layer
    // every user who switches it on would see.
    final files = Directory('assets/addons')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(files, isNotEmpty);
    final r = withBuiltInAddons(AddonLoadResult.empty, {
      for (final f in files) f.uri.pathSegments.last: f.readAsStringSync(),
    });
    expect(r.errors, isEmpty);
    expect(r.addons, hasLength(files.length));
    for (final a in r.addons) {
      expect(a.warnings, isEmpty, reason: '${a.id}: ${a.warnings}');
      expect(a.enabledByDefault, isFalse, reason: a.id);
      expect(a.id, startsWith('builtin.'));
    }
    expect(siteCollisions(r.addons), isEmpty);
    final tdwr = r.addons.firstWhere((a) => a.id == 'builtin.tdwr');
    expect(tdwr.sites, hasLength(45));
    expect(tdwr.sites.every((s) => s.isTdwr && s.level3 != null), isTrue);
  });

  test('theme keys match what the UI palette can set', () {
    // The data layer may not import the UI, so it keeps its own copy of the
    // key list. This is what stops the two drifting apart.
    expect(themeColorKeys, WxPalette.keys.toSet());
  });
}
