/// User file locations: imported `.pal` palettes and exported
/// snapshots. Plain filesystem paths, no plugins, so this works the same on
/// Linux, Windows, and (with the app's own data dir) Android.
library;

import 'dart:io';
import 'dart:typed_data';

/// `~/.config/radar-app/palettes`, created on first use with a README.
Directory paletteDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  final dir = Directory('$home/.config/radar-app/palettes');
  if (!dir.existsSync()) {
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
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  final dir = Directory('$home/Pictures/radar-app');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final now = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  final name = '${label}_${now.year}${p(now.month)}${p(now.day)}'
      '_${p(now.hour)}${p(now.minute)}${p(now.second)}.png';
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(png);
  return file;
}
