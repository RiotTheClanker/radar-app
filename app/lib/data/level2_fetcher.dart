/// Fetches complete NEXRAD Level 2 volumes from the Unidata open-data
/// mirror (`unidata-nexrad-level2`). Keys look like
/// `2026/07/28/KTLX/KTLX20260728_053715_V06`. Roughly one volume every
/// 4-10 minutes, available ~2 minutes after the volume completes.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

const _bucket = 'https://unidata-nexrad-level2.s3.amazonaws.com';

final _keyRe = RegExp(r'<Key>([^<]+)</Key>');

/// List the most recent [count] volume keys for a site, newest last.
Future<List<String>> listRecentVolumes(String icao, {int count = 3}) async {
  final now = DateTime.now().toUtc();
  final keys = <String>[];
  for (var back = 0; back < 2 && keys.length < count; back++) {
    final day = now.subtract(Duration(days: back));
    final prefix =
        '${day.year}/${_p(day.month)}/${_p(day.day)}/$icao/';
    final uri = Uri.parse('$_bucket/?list-type=2&prefix=$prefix&max-keys=1000');
    final resp = await http.get(uri);
    if (resp.statusCode != 200) continue;
    final dayKeys = _keyRe
        .allMatches(resp.body)
        .map((m) => m.group(1)!)
        .where((k) => !k.endsWith('_MDM'))
        .toList();
    keys.insertAll(0, dayKeys);
  }
  if (keys.length > count) {
    return keys.sublist(keys.length - count);
  }
  return keys;
}

/// Download one Level 2 volume (several MB).
Future<Uint8List> fetchVolume(String key) async {
  final resp = await http.get(Uri.parse('$_bucket/$key'));
  if (resp.statusCode != 200) {
    throw Exception('S3 GET $key failed: HTTP ${resp.statusCode}');
  }
  return resp.bodyBytes;
}

String _p(int v) => v.toString().padLeft(2, '0');
