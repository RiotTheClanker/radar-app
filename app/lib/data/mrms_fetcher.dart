/// MRMS national mosaic from the NOAA open-data bucket. Files land about
/// every two minutes and cover the whole CONUS in one grid, so this is what
/// the app shows when zoomed out past a single radar's range.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

const _bucket = 'https://noaa-mrms-pds.s3.amazonaws.com';
const _product = 'CONUS/MergedReflectivityQCComposite_00.50';

final _keyRe = RegExp(r'<Key>([^<]+)</Key>');

/// Most recent mosaic keys, newest last.
Future<List<String>> listRecentMosaics({int count = 1}) async {
  final now = DateTime.now().toUtc();
  final keys = <String>[];
  for (var back = 0; back < 2 && keys.length < count; back++) {
    final day = now.subtract(Duration(days: back));
    final stamp = '${day.year}${_p(day.month)}${_p(day.day)}';
    final uri = Uri.parse(
      '$_bucket/?list-type=2&prefix=$_product/$stamp/&max-keys=1000',
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) continue;
    final dayKeys =
        _keyRe.allMatches(resp.body).map((m) => m.group(1)!).toList();
    keys.insertAll(0, dayKeys);
  }
  if (keys.length > count) return keys.sublist(keys.length - count);
  return keys;
}

Future<Uint8List> fetchMosaic(String key) async {
  final resp = await http.get(Uri.parse('$_bucket/$key'));
  if (resp.statusCode != 200) {
    throw Exception('MRMS GET failed: HTTP ${resp.statusCode}');
  }
  return resp.bodyBytes;
}

String _p(int v) => v.toString().padLeft(2, '0');
