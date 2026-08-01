/// Hydrometeor classes, for the 3D legend.
///
/// The classifier itself lives in `rust/radar_core/src/process/hca.rs`, and
/// this is a copy of its class list: the ids are the palette indices the
/// renderer writes, so the two have to agree exactly. `test/hydrometeor_test`
/// reads the Rust source and fails if they drift apart, which is cheaper than
/// a bridge call for a table that changes about once a year.
library;

import 'package:flutter/material.dart';

class HydrometeorClass {
  final int id;
  final String label;
  final Color color;
  const HydrometeorClass(this.id, this.label, this.color);
}

const hydrometeorClasses = <HydrometeorClass>[
  HydrometeorClass(1, 'Ground clutter', Color(0xFF787878)),
  HydrometeorClass(2, 'Biological', Color(0xFF966EB4)),
  HydrometeorClass(3, 'Ice crystals', Color(0xFFB4E6FF)),
  HydrometeorClass(4, 'Dry snow', Color(0xFF6EBEFF)),
  HydrometeorClass(5, 'Wet snow', Color(0xFF4678DC)),
  HydrometeorClass(6, 'Graupel', Color(0xFFFFBE5A)),
  HydrometeorClass(7, 'Rain', Color(0xFF3CC85A)),
  HydrometeorClass(8, 'Heavy rain', Color(0xFF148232)),
  HydrometeorClass(9, 'Big drops', Color(0xFFE6E646)),
  HydrometeorClass(10, 'Hail / rain', Color(0xFFE63C3C)),
];
