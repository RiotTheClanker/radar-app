/// The addons that ship inside the app.
///
/// Each is an ordinary manifest under `assets/addons/`, in exactly the
/// format anyone else writes (docs/addons.md), so the extras we ship are
/// also worked examples and nothing about them is privileged. They start
/// switched off: every one of them is something some people want and most
/// do not, which is the line between an addon and a feature.
///
/// Read here rather than in `data/` because the asset bundle is Flutter's,
/// and `data/` stays plain Dart. What is read is handed to
/// [WorkspaceState.reloadAddons] as text.
library;

import 'package:flutter/services.dart';

/// Where the built-in manifests live in the asset bundle.
const builtInAddonPrefix = 'assets/addons/';

/// Every built-in manifest, by file name.
///
/// Found through the asset manifest, so adding one is dropping a `.json` in
/// the folder — the pubspec lists the folder, not the files. A manifest that
/// cannot be read is left out; the rest still load.
Future<Map<String, String>> loadBuiltInAddons({AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  final out = <String, String>{};
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(b);
    for (final path in manifest.listAssets()) {
      if (!path.startsWith(builtInAddonPrefix) ||
          !path.toLowerCase().endsWith('.json')) {
        continue;
      }
      try {
        out[path.substring(builtInAddonPrefix.length)] =
            await b.loadString(path);
      } catch (_) {}
    }
  } catch (_) {
    // No asset manifest (a test harness with no bundle): no built-ins.
  }
  return out;
}
