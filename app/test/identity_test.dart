import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/identity.dart';

void main() {
  test('appVersion tracks pubspec', () {
    // The version in identity.dart is hand-written, so it can drift away from
    // the real one at release time and quietly start lying in the User-Agent.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'no version: line in pubspec.yaml');
    expect(appVersion, m!.group(1),
        reason: 'bump appVersion in lib/data/identity.dart to match pubspec');
  });

  test('user agent names the app and a contact', () {
    // api.weather.gov blocks requests with a generic or absent UA, and asks
    // that one identify the app and give somewhere to reach the author.
    expect(userAgent, contains(appVersion));
    expect(userAgent, contains('https://'));
    expect(userAgent, isNot(contains('radar_app-dev')));
  });
}
