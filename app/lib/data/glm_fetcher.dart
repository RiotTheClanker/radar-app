/// GOES GLM satellite lightning: polls the open GOES-East/West buckets for
/// new 20-second LCFA files and parses them on-device via the Rust engine.
/// Fully open NOAA data (no usage restrictions), ~1-2 minutes behind
/// real-time, Americas coverage.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../src/rust/api/radar.dart';
import 'lightning.dart' show Strike;

const _buckets = ['noaa-goes19', 'noaa-goes18']; // East, West

final _keyRe = RegExp(r'<Key>([^<]+)</Key>');

class GlmClient {
  final _controller = StreamController<Strike>.broadcast();
  Timer? _timer;
  final Set<String> _seen = {};
  bool _running = false;

  Stream<Strike> get strikes => _controller.stream;

  void start() {
    if (_running) return;
    _running = true;
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    final now = DateTime.now().toUtc();
    for (final bucket in _buckets) {
      // Current hour, plus previous hour right after the top of the hour.
      final hours = [now, if (now.minute < 3) now.subtract(const Duration(hours: 1))];
      for (final h in hours) {
        try {
          await _pollHour(bucket, h);
        } catch (_) {
          // GLM is supplementary; ignore transient failures.
        }
      }
    }
    // Bound the de-dup set.
    if (_seen.length > 4000) {
      final keep = _seen.toList().sublist(_seen.length - 2000);
      _seen
        ..clear()
        ..addAll(keep);
    }
  }

  Future<void> _pollHour(String bucket, DateTime h) async {
    final doy = h
        .difference(DateTime.utc(h.year))
        .inDays + 1;
    final prefix = 'GLM-L2-LCFA/${h.year}/${doy.toString().padLeft(3, '0')}/'
        '${h.hour.toString().padLeft(2, '0')}/';
    final uri = Uri.parse(
      'https://$bucket.s3.amazonaws.com/?list-type=2&prefix=$prefix&max-keys=1000',
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return;
    final keys = _keyRe.allMatches(resp.body).map((m) => m.group(1)!).toList();
    // Only the newest few files; skip anything already ingested.
    final fresh =
        keys.reversed.take(6).where((k) => !_seen.contains(k)).toList();
    for (final key in fresh.reversed) {
      if (!_running) return;
      _seen.add(key);
      final data = await http.get(Uri.parse('https://$bucket.s3.amazonaws.com/$key'));
      if (data.statusCode != 200) continue;
      final glm = await parseGlm(data: Uint8List.fromList(data.bodyBytes));
      final t = DateTime.fromMillisecondsSinceEpoch(
        glm.timestamp.toInt() * 1000,
        isUtc: true,
      );
      for (var i = 0; i < glm.lats.length; i++) {
        _controller.add(Strike(t, LatLng(glm.lats[i], glm.lons[i])));
      }
    }
  }
}
