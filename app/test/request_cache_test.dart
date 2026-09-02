import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/request_cache.dart';

void main() {
  group('VolumeCache', () {
    test('panes asking at the same moment cause one fetch', () async {
      final cache = VolumeCache();
      var fetches = 0;
      Future<Uint8List> fetch() async {
        fetches++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return Uint8List.fromList([1, 2, 3]);
      }

      // The case this exists for: the Level 2 products a 2x2 compares all
      // read the same volume, and the panes ask for it together.
      final results = await Future.wait([
        for (var i = 0; i < 4; i++) cache.get('vol-a', fetch),
      ]);

      expect(fetches, 1);
      for (final r in results) {
        expect(r, [1, 2, 3]);
      }
    });

    test('a later ask is served without fetching again', () async {
      final cache = VolumeCache();
      var fetches = 0;
      Future<Uint8List> fetch() async {
        fetches++;
        return Uint8List.fromList([9]);
      }

      await cache.get('vol-a', fetch);
      await cache.get('vol-a', fetch);

      expect(fetches, 1);
      expect(cache['vol-a'], [9]);
    });

    test('a failed fetch reaches the caller and frees the key', () async {
      final cache = VolumeCache();
      var attempts = 0;
      Future<Uint8List> flaky() async {
        attempts++;
        if (attempts == 1) throw Exception('network');
        return Uint8List.fromList([7]);
      }

      await expectLater(cache.get('vol-a', flaky), throwsException);
      // One dropped request must not poison the key for the whole session.
      expect(await cache.get('vol-a', flaky), [7]);
      expect(attempts, 2);
    });

    test('every waiter on a failed fetch sees the failure', () async {
      final cache = VolumeCache();
      Future<Uint8List> boom() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw Exception('network');
      }

      final waiters = [for (var i = 0; i < 3; i++) cache.get('vol-a', boom)];
      for (final w in waiters) {
        await expectLater(w, throwsException);
      }
      expect(cache['vol-a'], isNull);
    });

    test('it stays bounded', () async {
      // These are the largest things the app holds, so an unbounded cache is
      // a slow leak across a long session.
      final cache = VolumeCache(maxEntries: 4);
      for (var i = 0; i < 20; i++) {
        await cache.get('vol-$i', () async => Uint8List.fromList([i]));
      }
      expect(cache.length, 4);
      expect(cache['vol-19'], isNotNull);
      expect(cache['vol-0'], isNull);
    });
  });

  group('Coalescer', () {
    test('simultaneous asks share one call', () async {
      final c = Coalescer<List<String>>();
      var calls = 0;
      Future<List<String>> list() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return ['k1'];
      }

      await Future.wait([for (var i = 0; i < 4; i++) c.run('site-a', list)]);
      expect(calls, 1);
    });

    test('it does not remember, because listings go stale', () async {
      final c = Coalescer<List<String>>();
      var calls = 0;
      Future<List<String>> list() async => [(calls++).toString()];

      await c.run('site-a', list);
      await c.run('site-a', list);

      // A new volume lands every few minutes; caching the listing would hide
      // it until something else forced a refresh.
      expect(calls, 2);
      expect(c.pending, 0);
    });

    test('different keys do not collide', () async {
      final c = Coalescer<List<String>>();
      final out = await Future.wait([
        c.run('a', () async => ['a']),
        c.run('b', () async => ['b']),
      ]);
      expect(out, [
        ['a'],
        ['b'],
      ]);
    });
  });
}
