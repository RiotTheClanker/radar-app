/// Stitches map tiles into a single north-up image for a lat/lon box, used
/// as the ground plane in the 3D view so you can tell where you are.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

class StitchedMap {
  final Uint8List rgba;
  final int width;
  final int height;
  StitchedMap(this.rgba, this.width, this.height);
}

int _lon2tile(double lon, int z) =>
    ((lon + 180.0) / 360.0 * (1 << z)).floor();

int _lat2tile(double lat, int z) {
  final r = lat * math.pi / 180.0;
  return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) /
          2 *
          (1 << z))
      .floor();
}

double _tile2lon(int x, int z) => x / (1 << z) * 360.0 - 180.0;

double _tile2lat(int y, int z) {
  final n = math.pi - 2 * math.pi * y / (1 << z);
  return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

/// Fetch and compose tiles covering [north]/[south]/[east]/[west] into one
/// image whose pixel grid is linear in longitude and latitude — which is
/// what the 3D ground plane expects. Over a single radar's extent the
/// Mercator-vs-linear error is well under a pixel.
Future<StitchedMap?> stitchBasemap({
  required String urlTemplate,
  required double north,
  required double south,
  required double east,
  required double west,
  int zoom = 8,
  int maxPixels = 1536,
}) async {
  final x0 = _lon2tile(west, zoom);
  final x1 = _lon2tile(east, zoom);
  final y0 = _lat2tile(north, zoom);
  final y1 = _lat2tile(south, zoom);
  final nx = x1 - x0 + 1;
  final ny = y1 - y0 + 1;
  if (nx <= 0 || ny <= 0 || nx * ny > 64) return null;

  final out = maxPixels.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, out, out),
    Paint()..color = const Color(0xFF10141A),
  );

  double px(double lon) => (lon - west) / (east - west) * out;
  double py(double lat) => (north - lat) / (north - south) * out;

  final futures = <Future<void>>[];
  for (var ty = y0; ty <= y1; ty++) {
    for (var tx = x0; tx <= x1; tx++) {
      final url = urlTemplate
          .replaceAll('{z}', '$zoom')
          .replaceAll('{x}', '$tx')
          .replaceAll('{y}', '$ty');
      futures.add(() async {
        try {
          final resp = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'radar_app-dev (open source radar app)'},
          ).timeout(const Duration(seconds: 8));
          if (resp.statusCode != 200) return;
          final codec = await ui.instantiateImageCodec(resp.bodyBytes);
          final img = (await codec.getNextFrame()).image;
          final dst = Rect.fromLTRB(
            px(_tile2lon(tx, zoom)),
            py(_tile2lat(ty, zoom)),
            px(_tile2lon(tx + 1, zoom)),
            py(_tile2lat(ty + 1, zoom)),
          );
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            dst,
            Paint()..filterQuality = FilterQuality.medium,
          );
          img.dispose();
        } catch (_) {
          // A missing tile just leaves that patch dark.
        }
      }());
    }
  }
  await Future.wait(futures);

  final picture = recorder.endRecording();
  final image = await picture.toImage(maxPixels, maxPixels);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) return null;
  return StitchedMap(bytes.buffer.asUint8List(), maxPixels, maxPixels);
}
