/// Fetches NEXRAD Level 3 product files from the Unidata open-data S3 bucket.
///
/// Bucket keys look like `TLX_N0B_2026_07_28_05_09_07` (site short id,
/// product, UTC timestamp). Listing with a date prefix returns keys in
/// ascending time order, so the newest frames are at the end.
library;

import 'package:http/http.dart' as http;

const _bucket = 'https://unidata-nexrad-level3.s3.amazonaws.com';

final _keyRe = RegExp(r'<Key>([^<]+)</Key>');

/// List the most recent [count] object keys for a site/product, newest last.
Future<List<String>> listRecentKeys(
  String siteShortId,
  String product, {
  int count = 10,
  DateTime? before,
}) async {
  final now = (before ?? DateTime.now()).toUtc();
  final keys = <String>[];
  // Walk backwards a day at a time until we have enough frames (radars in
  // maintenance can be quiet for a while; two days is plenty for an MVP).
  for (var back = 0; back < 2 && keys.length < count; back++) {
    final day = now.subtract(Duration(days: back));
    final prefix =
        '${siteShortId}_${product}_${day.year}_${_p(day.month)}_${_p(day.day)}';
    final uri = Uri.parse('$_bucket/?list-type=2&prefix=$prefix&max-keys=1000');
    final resp = await http.get(uri);
    if (resp.statusCode != 200) continue;
    var dayKeys =
        _keyRe.allMatches(resp.body).map((m) => m.group(1)!).toList();
    if (before != null) {
      // Keys embed a fixed-width UTC stamp, so a string compare is enough.
      final cut = '${siteShortId}_${product}_${now.year}_${_p(now.month)}_'
          '${_p(now.day)}_${_p(now.hour)}_${_p(now.minute)}_${_p(now.second)}';
      dayKeys = dayKeys.where((k) => k.compareTo(cut) <= 0).toList();
    }
    keys.insertAll(0, dayKeys);
  }
  if (keys.length > count) {
    return keys.sublist(keys.length - count);
  }
  return keys;
}

/// Download one product file.
Future<List<int>> fetchObject(String key) async {
  final resp = await http.get(Uri.parse('$_bucket/$key'));
  if (resp.statusCode != 200) {
    throw Exception('S3 GET $key failed: HTTP ${resp.statusCode}');
  }
  return resp.bodyBytes;
}

String _p(int v) => v.toString().padLeft(2, '0');
