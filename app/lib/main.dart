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

class RadarApp extends StatelessWidget {
  const RadarApp({super.key});

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
