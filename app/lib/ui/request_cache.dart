/// Fetch-once helpers for things several panes ask for at the same moment.
///
/// Four panes comparing Level 2 products are all reading the *same* Archive II
/// volume, and they ask for it simultaneously. Without something in the way
/// that is four downloads of the same 5-15 MB file and four copies retained.
///
/// Kept apart from [WorkspaceState] so it can be tested without starting an
/// alert poll and an animation timer — the logic here is about futures and a
/// map, and needs neither.
library;

import 'dart:typed_data';

/// Holds fetched bytes, and collapses duplicate in-flight fetches.
class VolumeCache {
  VolumeCache({this.maxEntries = 12});

  /// Roughly how many payloads to keep. These are the largest things the app
  /// holds, so the cache is bounded even though a bigger one would hit the
  /// network less.
  final int maxEntries;

  final Map<String, Uint8List> _bytes = {};
  final Map<String, Future<Uint8List>> _inFlight = {};

  /// What is already held, without starting a fetch.
  Uint8List? operator [](String key) => _bytes[key];

  int get length => _bytes.length;

  /// The bytes for [key], fetching only if no one else already is.
  Future<Uint8List> get(String key, Future<Uint8List> Function() fetch) {
    final held = _bytes[key];
    if (held != null) return Future.value(held);

    final pending = _inFlight[key];
    if (pending != null) return pending;

    // The stored future is the one handed back, so a failure reaches the
    // callers rather than becoming an unhandled async error — and the entry
    // is cleared either way, or one dropped request would poison the key for
    // the rest of the session.
    final future = fetch().then((bytes) {
      _bytes[key] = bytes;
      // Oldest-inserted out first. Dart maps keep insertion order, so the
      // first key is the least recently added.
      while (_bytes.length > maxEntries) {
        _bytes.remove(_bytes.keys.first);
      }
      return bytes;
      // Block body, deliberately. An arrow here returns what `remove` gives
      // back — which is this very future — and `whenComplete` waits on a
      // returned future, so the thing deadlocks on itself.
    }).whenComplete(() {
      _inFlight.remove(key);
    });

    _inFlight[key] = future;
    return future;
  }

  void clear() {
    _bytes.clear();
    _inFlight.clear();
  }
}

/// Collapses duplicate in-flight requests without keeping the results.
///
/// For answers that go stale — a listing of recent scans is worth sharing
/// between panes loading together, but not worth remembering, since the next
/// volume lands a few minutes later.
class Coalescer<T> {
  final Map<String, Future<T>> _inFlight = {};

  int get pending => _inFlight.length;

  Future<T> run(String key, Future<T> Function() fetch) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    // Block body: see the note in VolumeCache.get. `remove` hands back the
    // future being completed, and returning it from whenComplete deadlocks.
    final future = fetch().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }
}
