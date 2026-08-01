/// Hydrometeor classes, for the legends.
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

/// The NWS's own classes, for the Level 3 product shown on the 2D map.
///
/// A separate table from [hydrometeorClasses] on purpose: the same classes,
/// but the Level 3 product is coloured by `ColorTable::hydro_class_default`
/// in `rust/radar_core/src/render/color_table.rs`, and those colours are not
/// the ones our own classifier uses in 3D. Labelling the map with the 3D
/// palette would name every class wrongly — worse than having no legend,
/// since it misleads instead of merely omitting. `test/hydrometeor_test`
/// checks this against the Rust source.
///
/// It carries one class ours does not: "unknown", the algorithm declining to
/// answer.
const nwsHydrometeorClasses = <HydrometeorClass>[
  HydrometeorClass(10, 'Biological', Color(0xFF9C8064)),
  HydrometeorClass(20, 'Ground clutter', Color(0xFF5F5F5F)),
  HydrometeorClass(30, 'Ice crystals', Color(0xFFFFC8FF)),
  HydrometeorClass(40, 'Dry snow', Color(0xFF96B4FF)),
  HydrometeorClass(50, 'Wet snow', Color(0xFF466EFF)),
  HydrometeorClass(60, 'Rain', Color(0xFF00BE00)),
  HydrometeorClass(70, 'Heavy rain', Color(0xFF007800)),
  HydrometeorClass(80, 'Big drops', Color(0xFFE6C800)),
  HydrometeorClass(90, 'Graupel', Color(0xFFFF8C00)),
  HydrometeorClass(100, 'Hail / rain', Color(0xFFE60000)),
  HydrometeorClass(140, 'Unknown', Color(0xFF9600C8)),
];
