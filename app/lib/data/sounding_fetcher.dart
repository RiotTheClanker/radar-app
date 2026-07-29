/// Upper-air sounding (radiosonde) data.
///
/// SPC's observed soundings are the primary source: one small text file per
/// launch, on a host this app already talks to. NOAA's rucsoundings service
/// is the fallback, in a different text format again.
///
/// Both are free and keyless. Neither is IGRA, NOAA's full radiosonde
/// archive, which is the authoritative record but ships a station's whole
/// history as one zip — 80 MB for Norman — and lags a couple of days. Right
/// for research, wrong for "what went up tonight".
library;

import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// GSD marks every missing value with this.
const _missing = 99999;

/// One level of a sounding.
class SoundingLevel {
  /// Pressure, hPa.
  final double pressureHpa;

  /// Height above sea level, m. Null when the level did not report one.
  final double? heightM;

  /// Temperature and dewpoint, °C.
  final double? tempC;
  final double? dewpointC;

  /// Wind direction (degrees the wind is coming FROM) and speed in knots.
  final double? windDirDeg;
  final double? windKt;

  const SoundingLevel({
    required this.pressureHpa,
    this.heightM,
    this.tempC,
    this.dewpointC,
    this.windDirDeg,
    this.windKt,
  });

  bool get hasTemp => tempC != null;
  bool get hasWind => windDirDeg != null && windKt != null;
}

class Sounding {
  /// Station identifier as the service reported it, e.g. OUN.
  final String station;

  /// Header line, kept verbatim for display — it carries the observation
  /// time in the service's own words.
  final String title;
  final DateTime? time;
  final LatLng? position;
  final List<SoundingLevel> levels;

  const Sounding({
    required this.station,
    required this.title,
    required this.levels,
    this.time,
    this.position,
  });

  bool get isEmpty => levels.isEmpty;

  /// Surface level, which GSD flags with line type 9 but which is in practice
  /// the highest pressure reported.
  SoundingLevel? get surface => levels.isEmpty ? null : levels.first;
}

const _ua = {'User-Agent': 'radar_app-dev (open source radar app)'};

/// Fetch the most recent observed sounding for a station.
///
/// SPC first. Balloons go up at 00Z and 12Z, so the most recent launch is
/// found by walking back through synoptic hours rather than guessing — a file
/// appears an hour or so after release, so the newest slot is often not there
/// yet and the one before it is.
///
/// rucsoundings is kept as a fallback. It is NOAA's own sounding service and
/// serves a richer format, but it proved unreachable from at least one mobile
/// network ("no route to host") while spc.noaa.gov — which this app already
/// uses for outlooks and storm reports — was fine.
Future<Sounding?> fetchSounding(String station, {DateTime? now}) async {
  Object? firstError;
  for (final t in synopticTimes(now ?? DateTime.now().toUtc())) {
    try {
      final resp = await http
          .get(Uri.parse(spcSoundingUrl(station, t)), headers: _ua)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) continue;
      final s = parseSpcSounding(resp.body);
      if (s != null && !s.isEmpty) return s;
    } catch (e) {
      firstError ??= e;
    }
  }

  try {
    final s = await _fetchFromRucsoundings(station);
    if (s != null) return s;
  } catch (e) {
    firstError ??= e;
  }

  if (firstError != null) {
    throw Exception('could not reach a sounding service: $firstError');
  }
  return null;
}

/// The 00Z and 12Z slots to try, most recent first.
List<DateTime> synopticTimes(DateTime nowUtc, {int count = 4}) {
  final base = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day,
      nowUtc.hour >= 12 ? 12 : 0);
  return [for (var i = 0; i < count; i++) base.subtract(Duration(hours: 12 * i))];
}

/// SPC keeps observed soundings under a per-launch directory named for the
/// two-digit year, month, day and hour.
String spcSoundingUrl(String station, DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${two(t.year % 100)}${two(t.month)}${two(t.day)}${two(t.hour)}';
  return 'https://www.spc.noaa.gov/exper/soundings/${stamp}_OBS/'
      '${station.toUpperCase()}.txt';
}

Future<Sounding?> _fetchFromRucsoundings(String station,
    {int hoursBack = 24}) async {
  final nowSecs = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final uri = Uri.parse('https://rucsoundings.noaa.gov/get_soundings.cgi')
      .replace(queryParameters: {
    'data_source': 'RAOB',
    'latest': 'latest',
    'start': 'latest',
    'n_hrs': '$hoursBack',
    'airport': station,
    'hydrometeors': 'false',
    'startSecs': '${nowSecs - hoursBack * 3600}',
    'endSecs': '$nowSecs',
  });
  final resp =
      await http.get(uri, headers: _ua).timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) return null;
  final s = parseGsdSounding(resp.body);
  return (s == null || s.isEmpty) ? null : s;
}

/// Parse SPC's observed sounding text.
///
/// The interesting part sits between %RAW% and %END% as comma-separated
/// columns: pressure (mb), height (m), temperature and dewpoint (C), wind
/// direction (degrees) and speed (knots). Missing values are -9999.
Sounding? parseSpcSounding(String text) {
  if (!text.contains('%RAW%')) return null;
  final lines = text.split('\n');

  var title = '';
  var station = '';
  DateTime? time;
  var inRaw = false;
  final levels = <SoundingLevel>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line == '%RAW%') {
      inRaw = true;
      continue;
    }
    if (line == '%END%') break;
    if (!inRaw) {
      // "%TITLE%" then " OUN   260729/0000" — station id, then the launch
      // as YYMMDD/HHMM.
      if (line.isEmpty || line.startsWith('%')) continue;
      final m = RegExp(r'^([A-Za-z0-9]{3,5})\s+(\d{6})/(\d{4})')
          .firstMatch(line);
      if (m != null && station.isEmpty) {
        station = m.group(1)!.toUpperCase();
        title = line;
        final d = m.group(2)!;
        final t = m.group(3)!;
        final yy = int.tryParse(d.substring(0, 2));
        final mm = int.tryParse(d.substring(2, 4));
        final dd = int.tryParse(d.substring(4, 6));
        final hh = int.tryParse(t.substring(0, 2));
        final mi = int.tryParse(t.substring(2, 4));
        if (yy != null && mm != null && dd != null && hh != null) {
          time = DateTime.utc(2000 + yy, mm, dd, hh, mi ?? 0);
        }
      }
      continue;
    }

    final f = line.split(',');
    if (f.length < 6) continue;
    double? v(int i) {
      final d = double.tryParse(f[i].trim());
      // SPC uses -9999 for missing; a real reading never comes near it.
      if (d == null || d <= -999) return null;
      return d;
    }

    final p = v(0);
    if (p == null || p <= 0) continue;
    levels.add(SoundingLevel(
      pressureHpa: p,
      heightM: v(1),
      tempC: v(2),
      dewpointC: v(3),
      windDirDeg: v(4),
      windKt: v(5),
    ));
  }

  if (levels.isEmpty) return null;
  levels.sort((a, b) => b.pressureHpa.compareTo(a.pressureHpa));
  return Sounding(
    station: station,
    title: title,
    levels: levels,
    time: time,
  );
}

/// Parse the GSD ("Ascii text") sounding format.
///
/// Every line is whitespace-separated numbers whose first field is the line
/// type. Types 4 through 9 are data levels and share one layout:
///
///     type  pressure  height  temp  dewpoint  windDir  windSpeed
///
/// with pressure in tenths of a millibar and temperature and dewpoint in
/// tenths of a degree Celsius. Types 1 to 3 are the station header. Anything
/// unparseable is skipped rather than throwing: a partial sounding is still
/// worth showing, and this format is emitted by a CGI script that also
/// returns prose on error.
Sounding? parseGsdSounding(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty) return null;

  var title = '';
  var station = '';
  LatLng? position;
  final levels = <SoundingLevel>[];
  var windsInMs = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final fields = line.split(RegExp(r'\s+'));
    final first = int.tryParse(fields.first);

    // Non-numeric leading field: a header line. The first one is the title.
    if (first == null) {
      if (title.isEmpty) title = line;
      // "RAOB   OUN   observations at 00Z ..." — take the id when it looks
      // like one rather than a word.
      if (station.isEmpty && fields.length >= 2) {
        final candidate = fields[1];
        if (candidate.length <= 5 &&
            candidate == candidate.toUpperCase() &&
            RegExp(r'^[A-Z0-9]+$').hasMatch(candidate)) {
          station = candidate;
        }
      }
      continue;
    }

    switch (first) {
      case 1:
        // type, wban, wmo, lat, lon, elev, rtime — lat/lon in hundredths.
        if (fields.length >= 5) {
          final lat = _tenths(fields[3], 100);
          final lon = _tenths(fields[4], 100);
          if (lat != null && lon != null) position = LatLng(lat, lon);
        }
      case 2:
        // type, hydro, mxwd, tropl, lines, tindex, source — nothing needed.
        break;
      case 3:
        // type, staid, ---, sonde, wsunits
        if (fields.length >= 2 && station.isEmpty) station = fields[1];
        if (fields.length >= 5) windsInMs = fields[4].toLowerCase() == 'ms';
      case 4:
      case 5:
      case 6:
      case 7:
      case 8:
      case 9:
        if (fields.length < 7) break;
        final pressure = _tenths(fields[1], 10);
        if (pressure == null || pressure <= 0) break;
        final speed = _plain(fields[6]);
        levels.add(SoundingLevel(
          pressureHpa: pressure,
          heightM: _plain(fields[2]),
          tempC: _tenths(fields[3], 10),
          dewpointC: _tenths(fields[4], 10),
          windDirDeg: _plain(fields[5]),
          // GSD reports knots unless the header says metres per second.
          windKt: speed == null ? null : (windsInMs ? speed * 1.943844 : speed),
        ));
      default:
        break;
    }
  }

  if (levels.isEmpty) return null;
  // Surface first, thinning air upward. The service already orders it this
  // way, but significant and wind levels are interleaved by type in some
  // responses, so sort rather than trust it.
  levels.sort((a, b) => b.pressureHpa.compareTo(a.pressureHpa));

  return Sounding(
    station: station,
    title: title,
    levels: levels,
    time: _timeFromTitle(title),
    position: position,
  );
}

/// A GSD integer field scaled down, or null when it is the missing marker.
double? _tenths(String s, int divisor) {
  final v = int.tryParse(s);
  if (v == null || v.abs() == _missing) return null;
  return v / divisor;
}

double? _plain(String s) {
  final v = int.tryParse(s);
  if (v == null || v.abs() == _missing) return null;
  return v.toDouble();
}

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun',
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// Pull the observation time out of a header like
/// "RAOB  OUN  observations at 00Z 29 Jul 26".
DateTime? _timeFromTitle(String title) {
  final m = RegExp(
    r'(\d{1,2})Z\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})',
  ).firstMatch(title);
  if (m == null) return null;
  final hour = int.tryParse(m.group(1)!);
  final day = int.tryParse(m.group(2)!);
  final month = _months.indexOf(m.group(3)!.toLowerCase()) + 1;
  var year = int.tryParse(m.group(4)!);
  if (hour == null || day == null || month == 0 || year == null) return null;
  if (year < 100) year += 2000;
  return DateTime.utc(year, month, day, hour);
}

/// A US upper-air site. Coordinates are only used to pick the nearest one to
/// a radar, so a tenth of a degree either way changes nothing.
class RaobSite {
  final String id;
  final String name;
  final double lat;
  final double lon;
  const RaobSite(this.id, this.name, this.lat, this.lon);
}

/// CONUS radiosonde sites. Not the full global network — enough to find a
/// launch site near any NEXRAD.
const raobSites = <RaobSite>[
  RaobSite('OUN', 'Norman OK', 35.2, -97.4),
  RaobSite('LMN', 'Lamont OK', 36.7, -97.5),
  RaobSite('DDC', 'Dodge City KS', 37.8, -100.0),
  RaobSite('TOP', 'Topeka KS', 39.1, -95.6),
  RaobSite('SGF', 'Springfield MO', 37.2, -93.4),
  RaobSite('LZK', 'Little Rock AR', 34.8, -92.3),
  RaobSite('SHV', 'Shreveport LA', 32.5, -93.8),
  RaobSite('FWD', 'Fort Worth TX', 32.8, -97.3),
  RaobSite('CRP', 'Corpus Christi TX', 27.8, -97.5),
  RaobSite('BRO', 'Brownsville TX', 25.9, -97.4),
  RaobSite('DRT', 'Del Rio TX', 29.4, -100.9),
  RaobSite('MAF', 'Midland TX', 31.9, -102.2),
  RaobSite('AMA', 'Amarillo TX', 35.2, -101.7),
  RaobSite('EPZ', 'Santa Teresa NM', 31.9, -106.7),
  RaobSite('ABQ', 'Albuquerque NM', 35.0, -106.6),
  RaobSite('DNR', 'Denver CO', 39.8, -104.9),
  RaobSite('GJT', 'Grand Junction CO', 39.1, -108.5),
  RaobSite('RIW', 'Riverton WY', 43.1, -108.5),
  RaobSite('SLC', 'Salt Lake City UT', 40.8, -112.0),
  RaobSite('BOI', 'Boise ID', 43.6, -116.2),
  RaobSite('TFX', 'Great Falls MT', 47.5, -111.4),
  RaobSite('GGW', 'Glasgow MT', 48.2, -106.6),
  RaobSite('BIS', 'Bismarck ND', 46.8, -100.8),
  RaobSite('ABR', 'Aberdeen SD', 45.5, -98.4),
  RaobSite('RAP', 'Rapid City SD', 44.1, -103.2),
  RaobSite('LBF', 'North Platte NE', 41.1, -100.7),
  RaobSite('OAX', 'Omaha NE', 41.3, -96.4),
  RaobSite('MPX', 'Minneapolis MN', 44.8, -93.6),
  RaobSite('INL', 'International Falls MN', 48.6, -93.4),
  RaobSite('GRB', 'Green Bay WI', 44.5, -88.1),
  RaobSite('DVN', 'Davenport IA', 41.6, -90.6),
  RaobSite('ILX', 'Lincoln IL', 40.2, -89.3),
  RaobSite('APX', 'Gaylord MI', 45.1, -84.7),
  RaobSite('DTX', 'Detroit MI', 42.7, -83.5),
  RaobSite('ILN', 'Wilmington OH', 39.4, -83.8),
  RaobSite('PIT', 'Pittsburgh PA', 40.5, -80.2),
  RaobSite('BUF', 'Buffalo NY', 42.9, -78.7),
  RaobSite('ALB', 'Albany NY', 42.7, -73.8),
  RaobSite('OKX', 'Upton NY', 40.9, -72.9),
  RaobSite('CHH', 'Chatham MA', 41.7, -70.0),
  RaobSite('GYX', 'Gray ME', 43.9, -70.3),
  RaobSite('CAR', 'Caribou ME', 46.9, -68.0),
  RaobSite('IAD', 'Sterling VA', 38.9, -77.4),
  RaobSite('RNK', 'Blacksburg VA', 37.2, -80.4),
  RaobSite('MHX', 'Newport NC', 34.8, -76.9),
  RaobSite('GSO', 'Greensboro NC', 36.1, -79.9),
  RaobSite('CHS', 'Charleston SC', 32.9, -80.0),
  RaobSite('FFC', 'Peachtree City GA', 33.4, -84.6),
  RaobSite('JAX', 'Jacksonville FL', 30.5, -81.7),
  RaobSite('TBW', 'Tampa Bay FL', 27.7, -82.4),
  RaobSite('MFL', 'Miami FL', 25.8, -80.4),
  RaobSite('KEY', 'Key West FL', 24.6, -81.8),
  RaobSite('TLH', 'Tallahassee FL', 30.4, -84.3),
  RaobSite('BMX', 'Birmingham AL', 33.2, -86.8),
  RaobSite('JAN', 'Jackson MS', 32.3, -90.1),
  RaobSite('LCH', 'Lake Charles LA', 30.1, -93.2),
  RaobSite('LIX', 'Slidell LA', 30.3, -89.8),
  RaobSite('BNA', 'Nashville TN', 36.2, -86.6),
  RaobSite('OTX', 'Spokane WA', 47.7, -117.6),
  RaobSite('UIL', 'Quillayute WA', 47.9, -124.6),
  RaobSite('SLE', 'Salem OR', 44.9, -123.0),
  RaobSite('MFR', 'Medford OR', 42.4, -122.9),
  RaobSite('REV', 'Reno NV', 39.6, -119.8),
  RaobSite('LKN', 'Elko NV', 40.9, -115.7),
  RaobSite('VEF', 'Las Vegas NV', 36.0, -115.2),
  RaobSite('OAK', 'Oakland CA', 37.7, -122.2),
  RaobSite('VBG', 'Vandenberg CA', 34.8, -120.6),
  RaobSite('NKX', 'San Diego CA', 32.9, -117.1),
  RaobSite('TUS', 'Tucson AZ', 32.2, -110.9),
  RaobSite('FGZ', 'Flagstaff AZ', 35.2, -111.8),
];

/// The launch site closest to a point.
RaobSite nearestRaobSite(double lat, double lon) {
  var best = raobSites.first;
  var bestD = double.infinity;
  for (final s in raobSites) {
    // Flat approximation, fine over CONUS for a nearest-of check.
    final dy = s.lat - lat;
    final dx = (s.lon - lon) * math.cos(lat * math.pi / 180.0);
    final d = dy * dy + dx * dx;
    if (d < bestD) {
      bestD = d;
      best = s;
    }
  }
  return best;
}
