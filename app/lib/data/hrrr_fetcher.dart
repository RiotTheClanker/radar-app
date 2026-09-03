/// HRRR model fields, one field at a time.
///
/// The hourly file is around 130 MB and carries 170 fields. Alongside it sits
/// a `.idx` sidecar — a few kilobytes of text, one line per field, each
/// naming the byte offset where that field's GRIB2 message begins. Read the
/// index, find the field, and ask for that byte range: about 800 KB for
/// CAPE, which is a fifth of one Level 2 volume.
///
/// This is the only source in the app that is **model output** rather than a
/// measurement. Everything else was seen by an instrument. That difference
/// has to survive all the way to the screen, which is why [HrrrField] carries
/// the run time and why the caller is expected to show it.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'identity.dart';

const _bucket = 'https://noaa-hrrr-bdp-pds.s3.amazonaws.com';

/// The surface CAPE line in the index, exactly as HRRR labels it.
///
/// There are several CAPE fields in the file — mixed-layer over 180-0 mb,
/// another over 90-0 mb — and they are different numbers. This one is the
/// surface parcel.
const capeField = ':CAPE:surface:';

/// One field pulled out of a run.
class HrrrField {
  /// The raw GRIB2 message, for the engine to decode.
  final Uint8List bytes;

  /// When the model run started, UTC. Not when this was fetched: a forecast
  /// drawn without its run time invites being read as an observation.
  final DateTime runTime;

  const HrrrField(this.bytes, this.runTime);
}

/// One line of the `.idx`: `105:63553836:d=2026090312:CAPE:surface:anl:`
class _IndexEntry {
  final int offset;
  final String line;
  const _IndexEntry(this.offset, this.line);
}

List<_IndexEntry> _parseIndex(String body) {
  final out = <_IndexEntry>[];
  for (final line in body.split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split(':');
    // record : offset : date : parameter : level : ...
    if (parts.length < 3) continue;
    final offset = int.tryParse(parts[1]);
    if (offset == null) continue;
    out.add(_IndexEntry(offset, line));
  }
  return out;
}

/// Byte range of the record matching [needle], or null when it is absent.
///
/// The end is the next record's offset — GRIB2 messages are contiguous, and
/// the index gives no length. The final record has no successor, so it runs
/// to the end of the file and gets an open-ended range.
({int start, int? end})? _rangeFor(List<_IndexEntry> index, String needle) {
  for (var i = 0; i < index.length; i++) {
    if (!index[i].line.contains(needle)) continue;
    return (
      start: index[i].offset,
      end: i + 1 < index.length ? index[i + 1].offset - 1 : null,
    );
  }
  return null;
}

/// Runs are hourly and published with a lag, so the newest run on the bucket
/// is usually one or two hours behind the clock.
String _key(DateTime runUtc) {
  String p(int v) => v.toString().padLeft(2, '0');
  final d = '${runUtc.year}${p(runUtc.month)}${p(runUtc.day)}';
  return 'hrrr.$d/conus/hrrr.t${p(runUtc.hour)}z.wrfsfcf00.grib2';
}

/// Fetch one field from the most recent run that has it.
///
/// Walks back an hour at a time. [maxRunsBack] bounds that: a long outage
/// should surface as "no data" rather than as a slow crawl through a day of
/// missing files, and a stale forecast stops being worth drawing well before
/// then anyway.
Future<HrrrField?> fetchHrrrField(
  String field, {
  int maxRunsBack = 6,
  DateTime? now,
}) async {
  var run = (now ?? DateTime.now()).toUtc();
  run = DateTime.utc(run.year, run.month, run.day, run.hour);

  for (var back = 0; back < maxRunsBack; back++) {
    final at = run.subtract(Duration(hours: back));
    final base = '$_bucket/${_key(at)}';
    try {
      final idx = await http
          .get(Uri.parse('$base.idx'), headers: userAgentHeader)
          .timeout(const Duration(seconds: 15));
      if (idx.statusCode != 200) continue;

      final range = _rangeFor(_parseIndex(idx.body), field);
      if (range == null) continue;

      final headers = {
        ...userAgentHeader,
        'Range': 'bytes=${range.start}-${range.end ?? ''}',
      };
      final resp = await http
          .get(Uri.parse(base), headers: headers)
          .timeout(const Duration(seconds: 60));
      // 206 is the answer to a range request. A 200 means the range was
      // ignored and the whole 130 MB is arriving, which is not something to
      // accept quietly.
      if (resp.statusCode != 206) continue;
      return HrrrField(resp.bodyBytes, at);
    } catch (_) {
      // Try the previous run rather than giving up on the first timeout.
      continue;
    }
  }
  return null;
}

/// Exposed for tests: the index parsing and range arithmetic, which is where
/// this can silently fetch the wrong field.
({int start, int? end})? rangeForTest(String indexBody, String needle) =>
    _rangeFor(_parseIndex(indexBody), needle);

/// Exposed for tests: the object key for a run.
String keyForTest(DateTime runUtc) => _key(runUtc);
