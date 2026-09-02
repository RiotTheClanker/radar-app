/// One decoded radar image ready to be drawn on the map.
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../src/rust/api/radar.dart';

/// A [RadarFrame] from the engine, paired with the image and bounds the map
/// needs to draw it.
///
/// [image] and [bounds] are mutable because viewport sharpening replaces the
/// full-disk render with one cut to the visible box: same frame, same source
/// bytes, sharper picture over a smaller area.
class DisplayFrame {
  final RadarFrame meta;

  /// Source bytes the frame was decoded from, kept for the inspector and
  /// viewport re-renders.
  final Uint8List raw;

  /// Currently displayed overlay (swapped on viewport re-render).
  MemoryImage image;
  LatLngBounds bounds;

  DisplayFrame(this.meta, this.image, this.raw)
      : bounds = LatLngBounds(
          LatLng(meta.north, meta.west),
          LatLng(meta.south, meta.east),
        );

  /// Full extent of the radar data disk (from the initial whole-disk render).
  LatLngBounds get dataBounds => LatLngBounds(
        LatLng(meta.north, meta.west),
        LatLng(meta.south, meta.east),
      );

  /// Scan time, as UTC.
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(
        meta.timestamp.toInt() * 1000,
        isUtc: true,
      );
}
