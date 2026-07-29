/// Elevation for the 3D ground, from the free AWS Terrain Tiles open dataset.
///
/// Tiles are "terrarium" PNGs, which pack metres above sea level across the
/// three colour channels. That encoding cannot be resampled as an image —
/// blending two colours does not blend the two heights, and every 256 m
/// boundary in the red channel would come out as a spike — so tiles are
/// decoded to heights first and only then resampled.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

/// Public-domain elevation, no key required, same spirit as the NOAA buckets.
const _terrariumUrl =
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png';

class TerrainGrid {
  /// Metres above sea level, row-major from the north edge.
  final Float32List heights;
  final int width;
  final int height;
  const TerrainGrid(this.heights, this.width, this.height);
}

/// Decode one terrarium pixel. The dataset's own formula.
double terrariumHeight(int r, int g, int b) => (r * 256 + g + b / 256) - 32768;

int _lon2tile(double lon, int z) => ((lon + 180.0) / 360.0 * (1 << z)).floor();

int _lat2tile(double lat, int z) {
  final r = lat * math.pi / 180.0;
  return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z))
      .floor();
}

double _tile2lon(int x, int z) => x / (1 << z) * 360.0 - 180.0;

double _tile2lat(int y, int z) {
  final n = math.pi - 2 * math.pi * y / (1 << z);
  return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

/// Build a heightfield covering [north]/[south]/[east]/[west].
///
/// [zoom] 8 is about 600 m per pixel at mid latitudes, which is finer than
/// the grid this is sampled into and plenty for terrain under a radar volume.
Future<TerrainGrid?> fetchTerrain({
  required double north,
  required double south,
  required double east,
  required double west,
  int zoom = 8,
  int size = 256,
}) async {
  final x0 = _lon2tile(west, zoom);
  final x1 = _lon2tile(east, zoom);
  final y0 = _lat2tile(north, zoom);
  final y1 = _lat2tile(south, zoom);
  if (x1 < x0 || y1 < y0 || (x1 - x0 + 1) * (y1 - y0 + 1) > 64) return null;

  // Sea level where no tile answers, so a gap reads as flat rather than as a
  // chasm the camera can fall through.
  final out = Float32List(size * size);
  var anyTile = false;

  final futures = <Future<void>>[];
  for (var ty = y0; ty <= y1; ty++) {
    for (var tx = x0; tx <= x1; tx++) {
      futures.add(() async {
        final tile = await _tileHeights(tx, ty, zoom);
        if (tile == null) return;
        anyTile = true;
        final (heights, tw, th) = tile;

        // Where this tile lands in the output grid.
        final tNorth = _tile2lat(ty, zoom);
        final tSouth = _tile2lat(ty + 1, zoom);
        final tWest = _tile2lon(tx, zoom);
        final tEast = _tile2lon(tx + 1, zoom);

        for (var oy = 0; oy < size; oy++) {
          final lat = north - (oy + 0.5) / size * (north - south);
          if (lat > tNorth || lat < tSouth) continue;
          final sy = ((tNorth - lat) / (tNorth - tSouth) * th)
              .floor()
              .clamp(0, th - 1);
          for (var ox = 0; ox < size; ox++) {
            final lon = west + (ox + 0.5) / size * (east - west);
            if (lon < tWest || lon > tEast) continue;
            final sx = ((lon - tWest) / (tEast - tWest) * tw)
                .floor()
                .clamp(0, tw - 1);
            out[oy * size + ox] = heights[sy * tw + sx];
          }
        }
      }());
    }
  }
  await Future.wait(futures);
  if (!anyTile) return null;
  return TerrainGrid(out, size, size);
}

/// Fetch one tile and decode it to heights.
Future<(Float32List, int, int)?> _tileHeights(int x, int y, int z) async {
  try {
    final url = _terrariumUrl
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    final resp = await http.get(
      Uri.parse(url),
      headers: {'User-Agent': 'radar_app-dev (open source radar app)'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;

    final codec = await ui.instantiateImageCodec(resp.bodyBytes);
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = img.width;
    final h = img.height;
    img.dispose();
    if (data == null) return null;

    final px = data.buffer.asUint8List();
    final heights = Float32List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      heights[i] = terrariumHeight(px[o], px[o + 1], px[o + 2]);
    }
    return (heights, w, h);
  } catch (_) {
    // A missing tile just leaves that patch at sea level.
    return null;
  }
}
