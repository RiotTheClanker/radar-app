/// Current surface observations — the METAR network, as station plots.
///
/// One record carries temperature, dewpoint, wind and pressure together,
/// which is why this is a cheaper way to get those on the map than any
/// gridded field: it is a measurement, not an analysis, and it arrives as
/// JSON rather than as GRIB2 on a projection the engine cannot read.
///
/// It is also the more useful thing for nowcasting. A dewpoint gradient
/// between two stations is a boundary, and a boundary is where storms go up.
/// An interpolated field tends to smooth exactly that away.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'identity.dart';

/// Aviation Weather Center's METAR service: free, no key, and it takes a
/// bounding box, which is what makes one request enough for the whole map.
///
/// The only place the endpoint is named. If it moves, this is the line.
const _endpoint = 'https://aviationweather.gov/api/data/metar';

/// CONUS, with enough margin to cover every station a border radar can see.
///
/// One box for the whole country rather than the visible area: the obs are
/// shared by every pane, panning must not refetch, and the payload is around
/// 40 KB per 5x8 degrees — a few hundred KB for all of it, once every poll.
///
/// CONUS-only matches the MRMS mosaic, which is also CONUS-only, so the app
/// already has this coverage edge rather than gaining a new one here.
const _conus = (south: 24.0, west: -125.0, north: 50.0, east: -66.0);

/// A station stops being current well before it stops being interesting.
///
/// Routine METARs are hourly, with specials in between when conditions
/// change, so an hour-old observation is normal and a 90-minute-old one means
/// the station has most likely gone quiet. Drawn struck through rather than
/// dropped: a gap in the network is information, and silently showing nothing
/// looks the same as there being nothing there.
const obsStaleAfter = Duration(minutes: 90);

/// One station's latest observation.
class SurfaceObs {
  final String stationId;

  /// Human-readable, e.g. "Smith Center Arpt, KS, US".
  final String name;
  final LatLng pos;

  /// Metres above sea level, as the station reports itself.
  final double? elevM;

  final double? tempC;
  final double? dewpointC;

  /// Degrees the wind is coming *from*. Null when absent, and also when the
  /// station reports a variable wind — the API sends `"VRB"` there, which is
  /// a direction that does not exist rather than a number to round.
  final double? windDirDeg;
  final double? windKt;
  final double? gustKt;

  /// Altimeter setting, hPa.
  ///
  /// Named for what it is rather than as sea-level pressure, because it is
  /// not quite that: the reduction uses the standard atmosphere rather than
  /// the column's real temperature. Close enough to plot and to compare
  /// between neighbours; not the right input for a mean-sea-level analysis
  /// without correcting it first.
  final double? altimeterHpa;

  /// When the observation was taken, not when it was received.
  final DateTime time;

  const SurfaceObs({
    required this.stationId,
    required this.name,
    required this.pos,
    required this.time,
    this.elevM,
    this.tempC,
    this.dewpointC,
    this.windDirDeg,
    this.windKt,
    this.gustKt,
    this.altimeterHpa,
  });

  /// Whether this reading is old enough that it should not read as current.
  bool staleAt(DateTime now) => now.difference(time) > obsStaleAfter;

  /// Nothing worth drawing a station plot for.
  bool get isEmpty => tempC == null && dewpointC == null && windKt == null;
}

/// Read a number that the feed does not promise to send as one.
///
/// `wdir` is `"VRB"` when the wind will not sit still and `visib` is `"10+"`
/// when it is unlimited, so a plain cast throws on perfectly ordinary
/// weather. Anything unparseable becomes "not reported", which is what the
/// rest of the app already handles.
double? readNum(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Parse the service's JSON array. Exposed for tests.
List<SurfaceObs> parseSurfaceObs(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return const [];
  final out = <SurfaceObs>[];
  for (final row in decoded) {
    if (row is! Map) continue;
    final lat = readNum(row['lat']);
    final lon = readNum(row['lon']);
    final id = row['icaoId'];
    // Without a position there is nowhere to draw it, and without an id there
    // is nothing to call it. Everything else is optional.
    if (lat == null || lon == null || id is! String || id.isEmpty) continue;

    // Seconds since the epoch. Preferred over `reportTime` because it needs
    // no format assumptions, and over `receiptTime` because when a reading
    // reached a server is not when the air was that temperature.
    final secs = readNum(row['obsTime']);
    if (secs == null) continue;

    final obs = SurfaceObs(
      stationId: id,
      name: row['name'] is String ? row['name'] as String : id,
      pos: LatLng(lat, lon),
      time: DateTime.fromMillisecondsSinceEpoch(
        (secs * 1000).round(),
        isUtc: true,
      ),
      elevM: readNum(row['elev']),
      tempC: readNum(row['temp']),
      dewpointC: readNum(row['dewp']),
      windDirDeg: readNum(row['wdir']),
      windKt: readNum(row['wspd']),
      gustKt: readNum(row['wgst']),
      altimeterHpa: readNum(row['altim']),
    );
    // A station reporting none of the three is a row of nulls on the map.
    if (!obs.isEmpty) out.add(obs);
  }
  return out;
}

/// Fetch every current observation over CONUS.
Future<List<SurfaceObs>> fetchSurfaceObs() async {
  final uri = Uri.parse(
    '$_endpoint?bbox=${_conus.south},${_conus.west},'
    '${_conus.north},${_conus.east}&format=json',
  );
  final resp = await http
      .get(uri, headers: userAgentHeader)
      .timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw Exception('surface obs: HTTP ${resp.statusCode}');
  }
  // utf8 rather than resp.body: station names carry accents, and the default
  // latin1 fallback turns them into mojibake.
  return parseSurfaceObs(utf8.decode(resp.bodyBytes));
}
