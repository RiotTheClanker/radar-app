/// User file locations: imported `.pal` palettes and exported
/// snapshots. Plain filesystem paths, no plugins, so this works the same on
/// Linux, Windows, and (with the app's own data dir) Android.
library;

import 'dart:io';
import 'dart:typed_data';

import 'identity.dart';

String _home() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.systemTemp.path;

/// `~/.config/taa-yuku-radar/palettes`, created on first use with a README.
Directory paletteDir() {
  final dir = Directory('${_home()}/.config/$appSlug/palettes');
  if (!dir.existsSync()) {
    // Before the app had a name this lived under `radar-app`. Carry the old
    // directory over rather than silently losing someone's imported color
    // tables. Only ever done when there is nothing here to overwrite.
    final old = Directory('${_home()}/.config/radar-app/palettes');
    if (old.existsSync()) {
      try {
        dir.parent.createSync(recursive: true);
        old.renameSync(dir.path);
        return dir;
      } catch (_) {
        // Different filesystem, or no permission. Fall through and start
        // fresh; the old files stay where they are, untouched.
      }
    }
    dir.createSync(recursive: true);
    File('${dir.path}/README.txt').writeAsStringSync(
      'Drop .pal color table files here.\n'
      'They appear in the app under the palette menu.\n',
    );
  }
  return dir;
}

/// Available `.pal` files, sorted by name.
List<File> listPalettes() {
  final files = paletteDir()
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.pal'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// Save a PNG snapshot and return the file written.
File saveSnapshot(Uint8List png, String label) {
  final dir = Directory('${_home()}/Pictures/$appSlug');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final now = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  final name = '${label}_${now.year}${p(now.month)}${p(now.day)}'
      '_${p(now.hour)}${p(now.minute)}${p(now.second)}.png';
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(png);
  return file;
}
