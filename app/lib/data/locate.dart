/// Device location.
///
/// Real GPS where the device has it, falling back to IP geolocation. The two
/// are not interchangeable: IP geolocation on a phone resolves the carrier's
/// gateway, which can be a different city entirely, so it is a last resort
/// rather than the primary source.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Why a location attempt came back empty, so the user can be told something
/// more useful than nothing happening.
enum LocateFailure {
  /// Location services are switched off for the whole device.
  serviceDisabled,

  /// The user said no to the permission prompt.
  permissionDenied,

  /// Denied with "don't ask again"; only Settings can undo it.
  permissionDeniedForever,

  /// Nothing answered — no fix, no network, or both timed out.
  unavailable,
}

class LocateResult {
  /// Where the device is, or null when [failure] explains why not.
  final LatLng? position;
  final LocateFailure? failure;

  /// True when [position] came from GPS rather than the IP fallback, which
  /// is city-level at best.
  final bool precise;

  const LocateResult.found(LatLng this.position, {required this.precise})
      : failure = null;
  const LocateResult.failed(this.failure)
      : position = null,
        precise = false;

  String get message => switch (failure) {
        LocateFailure.serviceDisabled =>
          'Location is turned off for this device.',
        LocateFailure.permissionDenied =>
          'Radar needs location permission to find you.',
        LocateFailure.permissionDeniedForever =>
          'Location permission is blocked. Enable it in system settings.',
        _ => 'Could not work out where you are.',
      };
}

/// Best available fix: GPS first, then IP geolocation.
///
/// [askPermission] controls whether an undecided user is prompted. Startup
/// passes false — throwing a permission dialog at someone who has just opened
/// the app explains nothing — so the prompt belongs to the "my location"
/// button, where the user has asked for exactly this.
Future<LocateResult> locateDetailed({
  bool askPermission = true,
  @visibleForTesting Future<LatLng?> Function()? ipLookup,
}) async {
  final (gps, failure) = await _gps(askPermission);
  if (gps != null) return LocateResult.found(gps, precise: true);

  // Even when GPS is refused a rough position still beats dropping the user
  // on the default site, but the refusal is worth keeping to report.
  final ip = await (ipLookup ?? _viaIp)();
  if (ip != null) return LocateResult.found(ip, precise: false);
  return LocateResult.failed(failure ?? LocateFailure.unavailable);
}

/// Convenience for callers that only want a position.
Future<LatLng?> locate({bool askPermission = true}) async =>
    (await locateDetailed(askPermission: askPermission)).position;

/// GPS, or null plus the reason it could not be used.
Future<(LatLng?, LocateFailure?)> _gps(bool askPermission) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return (null, LocateFailure.serviceDisabled);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && askPermission) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return (null, LocateFailure.permissionDeniedForever);
    }
    if (permission == LocationPermission.denied) {
      return (null, LocateFailure.permissionDenied);
    }

    // A last known fix is instant and easily good enough to pick a radar
    // site, so take it rather than making the user wait on a cold start.
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return (LatLng(last.latitude, last.longitude), null);

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );
    return (LatLng(pos.latitude, pos.longitude), null);
  } catch (_) {
    // No plugin on this platform, no fix, or the wait ran out. The IP
    // fallback still has a chance.
    return (null, null);
  }
}

/// City-level position from the request's source address.
Future<LatLng?> _viaIp() async {
  try {
    final resp = await http
        .get(Uri.parse('https://ipapi.co/json/'))
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) return null;
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final lat = (j['latitude'] as num?)?.toDouble();
    final lon = (j['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  } catch (_) {
    return null;
  }
}
