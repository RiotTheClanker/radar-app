/// Real-time lightning strikes from the Blitzortung.org community network.
///
/// Protocol: connect to wss://ws{1,7,8}.blitzortung.org, send `{"a": 111}`,
/// and receive LZW-compressed JSON objects, one strike per message.
/// Community network, free for non-commercial use — we credit them in the UI.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class Strike {
  final DateTime time;
  final LatLng pos;
  Strike(this.time, this.pos);
}

/// Blitzortung's custom LZW variant (ported from their web client).
String _lzwDecode(String b) {
  final dict = <int, String>{};
  final data = b.split('');
  var currChar = data[0];
  var oldPhrase = currChar;
  final out = StringBuffer(currChar);
  var code = 256;
  for (var i = 1; i < data.length; i++) {
    final currCode = data[i].codeUnitAt(0);
    String phrase;
    if (currCode < 256) {
      phrase = data[i];
    } else {
      phrase = dict[currCode] ?? (oldPhrase + currChar);
    }
    out.write(phrase);
    currChar = phrase[0];
    dict[code] = oldPhrase + currChar;
    code++;
    oldPhrase = phrase;
  }
  return out.toString();
}

class BlitzortungClient {
  static const _hosts = [
    'wss://ws1.blitzortung.org/',
    'wss://ws7.blitzortung.org/',
    'wss://ws8.blitzortung.org/',
  ];

  final _controller = StreamController<Strike>.broadcast();
  WebSocket? _socket;
  bool _closed = false;
  int _hostIndex = 0;

  Stream<Strike> get strikes => _controller.stream;

  Future<void> start() async {
    _closed = false;
    unawaited(_connectLoop());
  }

  Future<void> _connectLoop() async {
    while (!_closed) {
      final host = _hosts[_hostIndex % _hosts.length];
      _hostIndex++;
      try {
        final socket = await WebSocket.connect(host)
            .timeout(const Duration(seconds: 10));
        _socket = socket;
        socket.add('{"a": 111}');
        await for (final msg in socket) {
          if (msg is! String || msg.isEmpty) continue;
          try {
            final json = jsonDecode(_lzwDecode(msg)) as Map<String, dynamic>;
            final lat = (json['lat'] as num?)?.toDouble();
            final lon = (json['lon'] as num?)?.toDouble();
            final timeNs = (json['time'] as num?)?.toInt();
            if (lat == null || lon == null || timeNs == null) continue;
            _controller.add(Strike(
              DateTime.fromMillisecondsSinceEpoch(timeNs ~/ 1000000,
                  isUtc: true),
              LatLng(lat, lon),
            ));
          } catch (_) {
            // Skip undecodable messages.
          }
        }
      } catch (_) {
        // fall through to reconnect
      }
      if (_closed) break;
      // Exponential-ish backoff capped at 30 s, jittered.
      final wait = 2 + math.Random().nextInt(28);
      await Future.delayed(Duration(seconds: wait));
    }
  }

  void stop() {
    _closed = true;
    _socket?.close();
    _socket = null;
  }
}
