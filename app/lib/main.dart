import 'package:flutter/material.dart';

import 'data/identity.dart';
import 'src/rust/frb_generated.dart';
import 'ui/workspace.dart';
import 'ui/wx_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const RadarApp());
}

class RadarApp extends StatefulWidget {
  const RadarApp({super.key});

  @override
  State<RadarApp> createState() => _RadarAppState();
}

class _RadarAppState extends State<RadarApp> {
  @override
  void initState() {
    super.initState();
    wxPaletteGeneration.addListener(_onPalette);
  }

  @override
  void dispose() {
    wxPaletteGeneration.removeListener(_onPalette);
    super.dispose();
  }

  /// A theme was switched. [MaterialApp] only rebuilds what depends on
  /// [Theme], but most of the chrome reads [Wx] directly, and a good deal of
  /// it sits under widgets that would otherwise be skipped as unchanged. So
  /// every element is marked dirty once. It costs one full rebuild, on a
  /// click that happens a handful of times in the app's life, and it keeps
  /// the workspace's state — panes, frames, layout — exactly where it was.
  ///
  /// After the frame rather than now: the workspace installs a remembered
  /// theme from its own `initState`, which runs inside this widget's build,
  /// and marking an ancestor dirty mid-build is an error.
  void _onPalette() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      void mark(Element e) {
        e.markNeedsBuild();
        e.visitChildren(mark);
      }

      (context as Element).visitChildren(mark);
    });
    // A theme picked from a menu arrives between frames, when nothing may be
    // scheduled to run that callback.
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: wxTheme(),
      home: const RadarWorkspace(),
    );
  }
}
