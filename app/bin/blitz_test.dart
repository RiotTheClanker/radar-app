// Quick connectivity test: dart run bin/blitz_test.dart
import 'dart:io';

import 'package:radar_app/data/lightning.dart';

Future<void> main() async {
  final client = BlitzortungClient();
  var n = 0;
  client.strikes.listen((s) {
    n++;
    if (n <= 5 || n % 50 == 0) {
      stdout.writeln('strike #$n ${s.time.toIso8601String()} ${s.pos}');
    }
  });
  await client.start();
  await Future.delayed(const Duration(seconds: 25));
  client.stop();
  stdout.writeln('total strikes in 25s: $n');
  exit(n > 0 ? 0 : 1);
}
