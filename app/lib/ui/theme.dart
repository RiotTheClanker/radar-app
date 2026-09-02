/// The app's one theme.
///
/// Dark-only, and not as a matter of taste: this app is used outdoors and in
/// the dark during severe weather, where a light UI both washes out the
/// radar colours and wrecks the user's night vision. The radar palettes are
/// also designed to be read against a dark ground.
library;

import 'package:flutter/material.dart';

/// Seed for the Material 3 scheme — the light blue of the app icon's sweep.
const seedColor = Color(0xFF29B6F6);

/// Ground the map paints under the tiles, and the fill behind the floating
/// bars and readout pills.
const mapBackground = Color(0xFF10141A);

ThemeData buildTheme() => ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );
