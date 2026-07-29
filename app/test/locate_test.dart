import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:radar_app/data/locate.dart';

/// Stands in for the device so the fallback chain can be exercised without a
/// real GPS or a network call.
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator({
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
    this.permissionAfterRequest,
    this.position,
  });

  final bool serviceEnabled;
  LocationPermission permission;
  final LocationPermission? permissionAfterRequest;
  final Position? position;

  /// Whether the user was actually prompted.
  bool didAsk = false;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    didAsk = true;
    return permissionAfterRequest ?? permission;
  }

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async =>
      position;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async =>
      position ?? (throw Exception('no fix'));
}

Position _at(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.utc(2026),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// The IP fallback, stubbed. Fails by default so tests must opt in.
Future<LatLng?> Function() _ip([LatLng? value]) => () async => value;

void main() {
  test('a GPS fix is used and reported as precise', () async {
    GeolocatorPlatform.instance = _FakeGeolocator(position: _at(35.3, -97.6));

    final r = await locateDetailed(ipLookup: _ip(const LatLng(0, 0)));

    expect(r.position, const LatLng(35.3, -97.6));
    expect(r.precise, isTrue, reason: 'GPS must not be labelled city-level');
  });

  test('a refused prompt falls back to IP, marked imprecise', () async {
    GeolocatorPlatform.instance = _FakeGeolocator(
      permission: LocationPermission.denied,
      permissionAfterRequest: LocationPermission.denied,
    );

    final r = await locateDetailed(ipLookup: _ip(const LatLng(41.9, -87.6)));

    expect(r.position, const LatLng(41.9, -87.6));
    expect(
      r.precise,
      isFalse,
      reason: 'an IP fix is the carrier gateway, not the user',
    );
  });

  test('with no GPS and no IP, the refusal is what gets reported', () async {
    GeolocatorPlatform.instance = _FakeGeolocator(
      permission: LocationPermission.deniedForever,
    );

    final r = await locateDetailed(ipLookup: _ip());

    expect(r.position, isNull);
    expect(r.failure, LocateFailure.permissionDeniedForever);
    expect(r.message, contains('system settings'));
  });

  test('location switched off is reported as such', () async {
    GeolocatorPlatform.instance = _FakeGeolocator(serviceEnabled: false);

    final r = await locateDetailed(ipLookup: _ip());

    expect(r.failure, LocateFailure.serviceDisabled);
    expect(r.message, contains('turned off'));
  });

  test('startup does not prompt, the button does', () async {
    final quiet = _FakeGeolocator(
      permission: LocationPermission.denied,
      permissionAfterRequest: LocationPermission.whileInUse,
      position: _at(35.3, -97.6),
    );
    GeolocatorPlatform.instance = quiet;
    await locateDetailed(askPermission: false, ipLookup: _ip());
    expect(quiet.didAsk, isFalse, reason: 'startup must stay silent');

    final asked = _FakeGeolocator(
      permission: LocationPermission.denied,
      permissionAfterRequest: LocationPermission.whileInUse,
      position: _at(35.3, -97.6),
    );
    GeolocatorPlatform.instance = asked;
    final r = await locateDetailed(ipLookup: _ip());
    expect(asked.didAsk, isTrue, reason: 'the button is what asks');
    expect(r.position, const LatLng(35.3, -97.6));
  });
}
