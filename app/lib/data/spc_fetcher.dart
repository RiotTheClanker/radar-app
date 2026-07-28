/// SPC severe weather products: convective outlooks and today's local storm
/// reports. Both are free public NWS/SPC feeds.
library;

import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// One categorical outlook area (SPC day 1-3 convective outlook).
class OutlookArea {
  final int dn;
  final String label;
  final Color color;
  final List<List<LatLng>> polygons;
  OutlookArea(this.dn, this.label, this.color, this.polygons);
}

/// SPC categorical risk codes, in ascending severity.
const _catNames = {
  2: 'General Thunderstorms',
  3: 'Marginal Risk',
  4: 'Slight Risk',
  5: 'Enhanced Risk',
  6: 'Moderate Risk',
  8: 'High Risk',
};

const _catColors = {
  2: Color(0xFF69B369),
  3: Color(0xFF7FC77F),
  4: Color(0xFFF6F67F),
  5: Color(0xFFE6C27F),
  6: Color(0xFFE67F7F),
  8: Color(0xFFFF7FFF),
};

/// One local storm report (tornado / hail / wind).
class StormReport {
  final String kind; // 'tornado' | 'hail' | 'wind'
  final String time;
  final String detail;
  final String location;
  final LatLng pos;
  StormReport(this.kind, this.time, this.detail, this.location, this.pos);

  Color get color => switch (kind) {
        'tornado' => const Color(0xFFFF1744),
        'hail' => const Color(0xFF00E5FF),
        _ => const Color(0xFF448AFF),
      };
}

const _headers = {'User-Agent': 'radar_app-dev (open source radar app)'};

/// Fetch the categorical convective outlook for day 1, 2, or 3.
Future<List<OutlookArea>> fetchOutlook({int day = 1}) async {
  final uri = Uri.parse(
    'https://www.spc.noaa.gov/products/outlook/day${day}otlk_cat.nolyr.geojson',
  );
  final resp = await http.get(uri, headers: _headers);
  if (resp.statusCode != 200) {
    throw Exception('SPC outlook failed: HTTP ${resp.statusCode}');
  }
  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final out = <OutlookArea>[];
  for (final f in (body['features'] as List? ?? [])) {
    final geom = f['geometry'];
    if (geom == null) continue;
    final props = f['properties'] as Map<String, dynamic>;
    final dn = (props['DN'] as num?)?.toInt() ?? 0;
    if (!_catNames.containsKey(dn)) continue;

    final polys = <List<LatLng>>[];
    void addRing(List ring) => polys.add([
          for (final c in ring)
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ]);
    final coords = geom['coordinates'] as List;
    if (geom['type'] == 'Polygon') {
      addRing(coords[0] as List);
    } else if (geom['type'] == 'MultiPolygon') {
      for (final p in coords) {
        addRing((p as List)[0] as List);
      }
    }
    out.add(OutlookArea(dn, _catNames[dn]!, _catColors[dn]!, polys));
  }
  // Draw milder risks first so severe areas land on top.
  out.sort((a, b) => a.dn.compareTo(b.dn));
  return out;
}

/// Today's local storm reports. The CSV concatenates tornado, hail, and wind
/// sections, each introduced by its own header row.
Future<List<StormReport>> fetchStormReports() async {
  final resp = await http.get(
    Uri.parse('https://www.spc.noaa.gov/climo/reports/today.csv'),
    headers: _headers,
  );
  if (resp.statusCode != 200) {
    throw Exception('SPC reports failed: HTTP ${resp.statusCode}');
  }
  final reports = <StormReport>[];
  var kind = 'tornado';
  for (final line in const LineSplitter().convert(resp.body)) {
    if (line.startsWith('Time,')) {
      kind = line.contains('F_Scale')
          ? 'tornado'
          : line.contains('Size')
              ? 'hail'
              : 'wind';
      continue;
    }
    final f = _splitCsv(line);
    if (f.length < 7) continue;
    final lat = double.tryParse(f[5]);
    final lon = double.tryParse(f[6]);
    if (lat == null || lon == null) continue;
    final detail = switch (kind) {
      'hail' => '${(int.tryParse(f[1]) ?? 0) / 100} in hail',
      'wind' => f[1] == 'UNK' ? 'wind damage' : '${f[1]} mph wind',
      _ => f[1] == 'UNK' ? 'tornado' : 'tornado (EF${f[1]})',
    };
    reports.add(
      StormReport(kind, f[0], detail, '${f[2]}, ${f[4]}', LatLng(lat, lon)),
    );
  }
  return reports;
}

/// Minimal CSV split that respects quoted fields.
List<String> _splitCsv(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (c == ',' && !quoted) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}
