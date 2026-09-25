/// Addon data sources: listing someone's bucket or index, and telling the
/// newest scan from the rest.
///
/// All against a mock client — the request shapes are the thing under test,
/// and a real server would make the tests about the server.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_app/data/radar_source.dart';

const _site = AddonSite(
  'XOKC',
  'Club',
  'OK',
  35.4,
  -97.6,
  1200,
  false,
  addonId: 'club',
);

void main() {
  group('templates', () {
    test('fill in site, product and date', () {
      expect(
        expandTemplate(
          'https://e.org/{site}/{site3}/{product}/{yyyy}{MM}{dd}/',
          site: _site,
          product: 'N0B',
          day: DateTime.utc(2026, 7, 8),
        ),
        'https://e.org/XOKC/OKC/N0B/20260708/',
      );
    });

    test('a short id can be given where it is not the last three letters', () {
      const s = AddonSite(
        'UNIV1',
        'U',
        '',
        1,
        2,
        0,
        false,
        addonId: 'u',
        shortIdOverride: 'UV1',
      );
      expect(expandTemplate('{site3}', site: s), 'UV1');
    });
  });

  group('reading times from file names', () {
    final t = DateTime.utc(2026, 7, 28, 5, 37, 15);
    for (final name in [
      '2026/07/28/KTLX/KTLX20260728_053715_V06',
      'TLX_N0B_2026_07_28_05_37_15',
      'radar-20260728-053715.gz',
      'scan_2026-07-28T05:37:15Z.ar2v',
    ]) {
      test(name, () => expect(entryTime(name), t));
    }

    test('minutes-only stamps', () {
      expect(
        entryTime('KTLX_20260728_0537.nids'),
        DateTime.utc(2026, 7, 28, 5, 37),
      );
    });

    test('a dated folder does not stand in for an undated file', () {
      expect(
        entryTime('2026/07/28/latest'),
        isNull,
        reason: 'folder dates have no time of day to offer',
      );
    });

    test('nonsense digits are not a date', () {
      expect(entryTime('file_20261399_999999'), isNull);
    });
  });

  group('index listings', () {
    final base = Uri.parse('https://e.org/l3/OKC/N0B/');

    test('JSON of names and objects', () {
      final e = parseIndex(
        '[ "a_20260101_000000", {"url": "b", "time": "2026-01-01T00:05:00Z"} ]',
        base,
      );
      expect(e.map((x) => x.url), [
        'https://e.org/l3/OKC/N0B/a_20260101_000000',
        'https://e.org/l3/OKC/N0B/b',
      ]);
      expect(e.last.time, DateTime.utc(2026, 1, 1, 0, 5));
    });

    test('JSON object holding a file list', () {
      final e = parseIndex('{"files": [{"name": "x"}]}', base);
      expect(e.single.url, 'https://e.org/l3/OKC/N0B/x');
    });

    test('a web server directory listing', () {
      const html = '''
<html><body><h1>Index of /l3/OKC/N0B/</h1>
<a href="../">../</a>
<a href="?C=M;O=A">Last modified</a>
<a href="sub/">sub/</a>
<a href="OKC_N0B_2026_01_01_00_00_00">OKC_N0B_2026_01_01_00_00_00</a>
<a href='OKC_N0B_2026_01_01_00_05_00'>x</a>
<a href="notes.txt">notes.txt</a>
</body></html>''';
      final e = parseIndex(html, base, match: RegExp(r'N0B_\d'));
      expect(e.map((x) => x.url.split('/').last), [
        'OKC_N0B_2026_01_01_00_00_00',
        'OKC_N0B_2026_01_01_00_05_00',
      ]);
    });

    test('plain text, one per line, absolute URLs kept', () {
      final e = parseIndex('# comment\nhttps://cdn.e.org/f1\n\nf2\n', base);
      expect(e.map((x) => x.url), [
        'https://cdn.e.org/f1',
        'https://e.org/l3/OKC/N0B/f2',
      ]);
    });
  });

  group('listing a source', () {
    test(
      'S3: walks back by day, pages, filters, and keeps the newest',
      () async {
        final asked = <String>[];
        final client = MockClient((req) async {
          asked.add(req.url.toString());
          final prefix = req.url.queryParameters['prefix']!;
          final token = req.url.queryParameters['continuation-token'];
          if (prefix == '2026/07/28/XOKC/') {
            if (token == null) {
              return http.Response('''
<ListBucketResult><IsTruncated>true</IsTruncated>
<Key>2026/07/28/XOKC/XOKC20260728_000100_V06</Key>
<Key>2026/07/28/XOKC/XOKC20260728_000100_V06_MDM</Key>
<NextContinuationToken>t&amp;1</NextContinuationToken>
</ListBucketResult>''', 200);
            }
            expect(token, 't&1', reason: 'the token is unescaped');
            return http.Response('''
<ListBucketResult><IsTruncated>false</IsTruncated>
<Key>2026/07/28/XOKC/XOKC20260728_000600_V06</Key>
</ListBucketResult>''', 200);
          }
          if (prefix == '2026/07/27/XOKC/') {
            return http.Response('''
<ListBucketResult>
<Key>2026/07/27/XOKC/XOKC20260727_235500_V06</Key>
</ListBucketResult>''', 200);
          }
          return http.Response('<ListBucketResult/>', 200);
        });
        final src = DataSource(
          kind: SourceKind.s3,
          url: 'https://bucket.e.org/',
          prefix: '{yyyy}/{MM}/{dd}/{site}/',
          match: RegExp(r'_V06$'),
        );
        final keys = await listSource(
          src,
          site: _site,
          count: 3,
          before: DateTime.utc(2026, 7, 28, 1),
          client: client,
        );
        expect(keys, [
          'https://bucket.e.org/2026/07/27/XOKC/XOKC20260727_235500_V06',
          'https://bucket.e.org/2026/07/28/XOKC/XOKC20260728_000100_V06',
          'https://bucket.e.org/2026/07/28/XOKC/XOKC20260728_000600_V06',
        ]);
        expect(asked.first, startsWith('https://bucket.e.org/?list-type=2'));
      },
    );

    test(
      'replay drops files after the moment, and files with no time',
      () async {
        final client = MockClient(
          (req) async => http.Response(
            'f_20260101_000000\nf_20260101_001000\nundated\n',
            200,
          ),
        );
        final keys = await listSource(
          const DataSource(kind: SourceKind.listing, url: 'https://e.org/'),
          site: _site,
          before: DateTime.utc(2026, 1, 1, 0, 5),
          client: client,
        );
        expect(keys, ['https://e.org/f_20260101_000000']);
      },
    );

    test('headers are sent, with ours underneath', () async {
      late Map<String, String> sent;
      final client = MockClient((req) async {
        sent = req.headers;
        return http.Response('[]', 200);
      });
      await listSource(
        const DataSource(
          kind: SourceKind.listing,
          url: 'https://e.org/',
          headers: {'Authorization': 'Bearer k'},
        ),
        site: _site,
        client: client,
      );
      expect(sent['Authorization'], 'Bearer k');
      expect(sent['User-Agent'], startsWith('taa-yuku-radar/'));
    });

    test("a source's headers never follow a file to another host", () async {
      final seen = <String, String?>{};
      final client = MockClient((req) async {
        seen[req.url.host] = req.headers['Authorization'];
        return http.Response('x', 200);
      });
      const src = DataSource(
        kind: SourceKind.listing,
        url: 'https://data.e.org/{site}/',
        headers: {'Authorization': 'Bearer k'},
      );
      await fetchSourceObject(
        src,
        'https://data.e.org/XOKC/f1',
        client: client,
      );
      await fetchSourceObject(src, 'https://cdn.other.org/f2', client: client);
      expect(seen['data.e.org'], 'Bearer k');
      expect(seen.containsKey('cdn.other.org'), isTrue);
      expect(seen['cdn.other.org'], isNull);
    });

    test('a server error is reported, not read as "no scans"', () async {
      final client = MockClient((req) async => http.Response('', 500));
      await expectLater(
        listSource(
          const DataSource(kind: SourceKind.listing, url: 'https://e.org/'),
          site: _site,
          client: client,
        ),
        throwsException,
      );
    });
  });

  group('a folder on this device', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('folder_src'));
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'lists by template, filters, orders by name or modified time',
      () async {
        final ref = Directory('${dir.path}/XOKC/REF/2')
          ..createSync(recursive: true);
        File('${ref.path}/scan_20260101_000500.json').writeAsStringSync('b');
        File('${ref.path}/scan_20260101_000000.json').writeAsStringSync('a');
        File('${ref.path}/notes.txt').writeAsStringSync('x');
        File('${ref.path}/.hidden.json').writeAsStringSync('x');
        final undated = File('${ref.path}/latest.json')..writeAsStringSync('c');
        undated.setLastModifiedSync(DateTime.utc(2026, 1, 1, 0, 10));

        final src = DataSource(
          kind: SourceKind.folder,
          url: '${dir.path}/{site}/{product}/{tilt}',
          match: RegExp(r'\.json$'),
        );
        final keys = await listSource(
          src,
          site: _site,
          product: 'REF',
          tilt: 2,
        );
        expect(
          keys.map((k) => k.split('/').last),
          [
            'scan_20260101_000000.json',
            'scan_20260101_000500.json',
            'latest.json',
          ],
          reason: 'an undated file is placed by when it was written',
        );

        final bytes = await fetchSourceObject(src, keys.first);
        expect(String.fromCharCodes(bytes), 'a');
      },
    );

    test('a folder that does not exist yet is an empty listing', () async {
      final keys = await listSource(
        DataSource(kind: SourceKind.folder, url: '${dir.path}/nope/{product}'),
        site: _site,
        product: 'REF',
      );
      expect(keys, isEmpty);
    });

    test('a key outside the folder is refused', () async {
      final src = DataSource(kind: SourceKind.folder, url: '${dir.path}/data');
      await expectLater(fetchSourceObject(src, '/etc/passwd'), throwsException);
    });
  });

  group('which source a site uses', () {
    test('a new site with no Level 3 source says so rather than borrowing '
        "NOAA's under a three-letter id", () async {
      await expectLater(
        listSiteLevel3(_site, 'N0B'),
        throwsA(isA<NoSourceException>()),
      );
    });

    test("an addon site's source is the one listed", () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'club.e.org');
        expect(req.url.path, '/OKC/N0G/');
        return http.Response('OKC_N0G_2026_01_01_00_00_00\n', 200);
      });
      const site = AddonSite(
        'XOKC',
        'Club',
        'OK',
        35.4,
        -97.6,
        1200,
        false,
        addonId: 'club',
        level3: DataSource(
          kind: SourceKind.listing,
          url: 'https://club.e.org/{site3}/{product}/',
        ),
      );
      final keys = await listSiteLevel3(site, 'N0G', client: client);
      expect(
        keys.single,
        'https://club.e.org/OKC/N0G/OKC_N0G_2026_01_01_00_00_00',
      );
    });
  });
}
