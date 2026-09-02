import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'data/alerts_fetcher.dart';
import 'data/hydrometeor.dart';
import 'data/identity.dart';
import 'data/lightning.dart';
import 'data/nexrad_sites.g.dart';
import 'data/sounding_fetcher.dart';
import 'data/user_files.dart';
import 'model/models.dart';
import 'src/rust/api/radar.dart';
import 'src/rust/frb_generated.dart';
import 'state/radar_controller.dart';
import 'ui/color_key.dart';
import 'ui/hydro_legend.dart';
import 'ui/sounding_screen.dart';
import 'ui/theme.dart';
import 'ui/toolbar.dart';
import 'ui/volume3d_screen.dart';

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
      theme: buildTheme(),
      home: const RadarScreen(),
    );
  }
}

/// The map screen.
///
/// All state and data loading live in [RadarController]; this widget reads
/// it, draws it, and owns the things that genuinely need a `BuildContext` —
/// the map camera, bottom sheets, dialogs, snack bars and navigation.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  final _c = RadarController();
  final _mapController = MapController();
  final LayerHitNotifier<WeatherAlert> _alertHit = ValueNotifier(null);

  @override
  void initState() {
    super.initState();

    // The controller has no BuildContext, so the two things it needs from
    // the view — where the camera is looking, and how to move it — are
    // handed in here.
    _c.viewport = () {
      if (!mounted) return null;
      try {
        final cam = _mapController.camera;
        final vis = cam.visibleBounds;
        final media = MediaQuery.of(context);
        return MapViewport(
          north: vis.north,
          south: vis.south,
          east: vis.east,
          west: vis.west,
          zoom: cam.zoom,
          pixelWidth: media.size.width * media.devicePixelRatio,
        );
      } catch (_) {
        // Map not attached yet (a load can finish before the first frame).
        return null;
      }
    };
    _c.onMoveMap = (center, zoom) => _mapController.move(center, zoom);
    _c.messages.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(msg)));
    });

    _c.start();
  }

  @override
  void dispose() {
    _c.dispose();
    _alertHit.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ actions ----

  /// Jump the whole app to a past moment (or back to live). The pickers are
  /// the view's business; the controller only takes the answer.
  Future<void> _pickHistory() async {
    if (_c.historyTime != null) {
      _c.setHistoryTime(null);
      return;
    }
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1991),
      lastDate: now,
      helpText: 'Replay a past storm',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
      helpText: 'Local time to replay',
    );
    if (time == null || !mounted) return;
    _c.setHistoryTime(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  /// Open the 3D volume view on the Level 2 volume for this site, at the
  /// moment currently being shown.
  Future<void> _open3D() async {
    final bytes = await _c.prepareVolume();
    if (bytes == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Volume3DScreen(
          volumeBytes: bytes,
          siteId: _c.site.icao,
          basemapUrl: _c.basemap.url,
        ),
      ),
    );
  }

  /// Open the sounding for the launch site nearest whatever we are looking
  /// at — the radar site, or the user's own position if we have one.
  void _openSounding() {
    final here = _c.myLocation ?? LatLng(_c.site.lat, _c.site.lon);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SoundingScreen(
        site: nearestRaobSite(here.latitude, here.longitude),
      ),
    ));
  }

  /// A tap with the cursor active either releases the pin (when it landed on
  /// the pin itself) or re-aims. The 24 px hit test needs the camera, which
  /// is why it lives here rather than in the controller.
  void _onCursorTap(LatLng p) {
    final existing = _c.cursorPos;
    if (_c.cursorPinned && existing != null) {
      final cam = _mapController.camera;
      final d = (cam.latLngToScreenOffset(existing) -
              cam.latLngToScreenOffset(p))
          .distance;
      if (d < 24) {
        _c.unpinCursor();
        return;
      }
    }
    _c.aimCursor(p, fromTap: true);
  }

  /// Frame an alert's polygon on the map.
  void _zoomToAlert(WeatherAlert a) {
    var north = -90.0, south = 90.0, east = -180.0, west = 180.0;
    for (final ring in a.polygons) {
      for (final p in ring) {
        north = math.max(north, p.latitude);
        south = math.min(south, p.latitude);
        east = math.max(east, p.longitude);
        west = math.min(west, p.longitude);
      }
    }
    if (north <= south || east <= west) return;
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(LatLng(north, west), LatLng(south, east)),
        padding: const EdgeInsets.all(48),
      ),
    );
  }

  CircleMarker _strikeCircle(Strike s) {
    final ageMin = DateTime.now().toUtc().difference(s.time).inSeconds / 60.0;
    // Fresh strikes: bright white-yellow; fading to dim orange over 20 min.
    final t = (ageMin / 20.0).clamp(0.0, 1.0);
    final color = Color.lerp(
      const Color(0xFFFFF59D),
      const Color(0x66E65100),
      t,
    )!;
    return CircleMarker(
      point: s.pos,
      radius: ageMin < 2 ? 3.5 : 2.5,
      color: color,
    );
  }

  // ----------------------------------------------------------------- ui ----

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final frame = _c.displayedFrame;
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(_c.site.lat, _c.site.lon),
              initialZoom: 7,
              minZoom: 3,
              maxZoom: 15,
              onTap: (tapPos, latlng) {
                if (_c.measuring) _c.addMeasurePoint(latlng);
                if (_c.cursorEnabled) _onCursorTap(latlng);
              },
              onPointerHover: (event, latlng) {
                if (_c.cursorEnabled) _c.aimCursor(latlng);
              },
              onLongPress: (tapPos, latlng) => _c.inspect(latlng),
              // Pinch-zoom and drag, but no accidental two-finger rotation:
              // a twisted radar map is disorienting and hard to undo on touch.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapEvent: (e) => _c.onMapMoved(e.camera.zoom),
              backgroundColor: mapBackground,
            ),
            children: [
              TileLayer(
                urlTemplate: _c.basemap.url,
                userAgentPackageName: appId,
              ),
              if (frame != null)
                OverlayImageLayer(
                  overlayImages: [
                    OverlayImage(
                      bounds: frame.bounds,
                      imageProvider: frame.image,
                      gaplessPlayback: true,
                    ),
                  ],
                ),
              if (_c.showOutlook)
                PolygonLayer(
                  polygons: [
                    for (final a in _c.outlook)
                      for (final ring in a.polygons)
                        Polygon(
                          points: ring,
                          color: a.color.withValues(alpha: 0.16),
                          borderColor: a.color.withValues(alpha: 0.9),
                          borderStrokeWidth: 1.5,
                        ),
                  ],
                ),
              GestureDetector(
                onTap: () {
                  final hit = _alertHit.value;
                  if (hit != null && hit.hitValues.isNotEmpty) {
                    _showAlertSheet(hit.hitValues.first);
                  }
                },
                child: PolygonLayer(
                  hitNotifier: _alertHit,
                  polygons: [
                    for (final a in _c.alerts)
                      if (_c.alertLayers.contains(a.category))
                        for (final ring in a.polygons)
                          Polygon(
                            points: ring,
                            hitValue: a,
                            // Watches and advisories sit under the warnings
                            // rather than competing with them.
                            color: a.color.withValues(
                              alpha: a.category == AlertCategory.warning
                                  ? 0.12
                                  : 0.07,
                            ),
                            borderColor: a.color.withValues(
                              alpha: a.category == AlertCategory.warning
                                  ? 1.0
                                  : 0.75,
                            ),
                            borderStrokeWidth:
                                a.category == AlertCategory.warning ? 2 : 1.2,
                          ),
                  ],
                ),
              ),
              if (_c.showLightning)
                CircleLayer(
                  circles: [for (final s in _c.strikes) _strikeCircle(s)],
                ),
              if (_c.showReports)
                MarkerLayer(
                  markers: [
                    for (final r in _c.reports)
                      Marker(
                        point: r.pos,
                        width: 16,
                        height: 16,
                        child: GestureDetector(
                          onTap: () => ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              SnackBar(
                                duration: const Duration(seconds: 5),
                                content: Text(
                                  '${r.time}Z  ${r.detail} — ${r.location}',
                                ),
                              ),
                            ),
                          child: Icon(
                            r.kind == 'tornado'
                                ? Icons.cyclone
                                : r.kind == 'hail'
                                    ? Icons.ac_unit
                                    : Icons.air,
                            size: 15,
                            color: r.color,
                            shadows: const [
                              Shadow(blurRadius: 3, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              if (_c.cursorEnabled &&
                  _c.cursorPos != null &&
                  _c.cursorSite != null) ...[
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _c.cursorSite!,
                      // Geometric, so the ring always passes exactly through
                      // the crosshair — even outside radar coverage, where
                      // there is no sample to take a distance from.
                      radius: distanceBearing(_c.cursorSite!, _c.cursorPos!).$1 *
                          1000,
                      useRadiusInMeter: true,
                      color: Colors.transparent,
                      borderColor: Colors.amberAccent.withValues(alpha: 0.85),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_c.cursorSite!, _c.cursorPos!],
                      color: Colors.amberAccent.withValues(alpha: 0.9),
                      strokeWidth: 1.5,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _c.cursorPos!,
                      width: 26,
                      height: 26,
                      child: IgnorePointer(
                        child: Icon(
                          _c.cursorPinned ? Icons.gps_fixed : Icons.add,
                          size: _c.cursorPinned ? 22 : 26,
                          color: Colors.amberAccent,
                          shadows: const [
                            Shadow(blurRadius: 3, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_c.measurePts.length == 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _c.measurePts,
                      color: Colors.cyanAccent,
                      strokeWidth: 2,
                    ),
                  ],
                ),
              if (_c.measuring)
                MarkerLayer(
                  markers: [
                    for (final p in _c.measurePts)
                      Marker(
                        point: p,
                        width: 12,
                        height: 12,
                        child: const Icon(
                          Icons.circle,
                          size: 10,
                          color: Colors.cyanAccent,
                        ),
                      ),
                  ],
                ),
              if (_c.samplePos != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _c.samplePos!,
                      width: 18,
                      height: 18,
                      child: const Icon(
                        Icons.add_circle_outline,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              if (_c.tracksEnabled) ...[
                // Projected path, then the cell itself on top of it.
                PolylineLayer(
                  polylines: [
                    for (final s in _c.stormTracks)
                      if (s.forecast.isNotEmpty)
                        Polyline(
                          points: [
                            LatLng(s.lat, s.lon),
                            for (final f in s.forecast) LatLng(f.lat, f.lon),
                          ],
                          color: Colors.white.withValues(alpha: 0.85),
                          strokeWidth: 2,
                        ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final s in _c.stormTracks) ...[
                      for (final f in s.forecast)
                        Marker(
                          point: LatLng(f.lat, f.lon),
                          width: 30,
                          height: 14,
                          child: Text(
                            '${f.minutes.round()}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              shadows: [
                                Shadow(blurRadius: 3, color: Colors.black),
                              ],
                            ),
                          ),
                        ),
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 108,
                        height: 34,
                        child: GestureDetector(
                          onTap: () => _showTrackSheet(s),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                s.tracked
                                    ? Icons.change_history
                                    : Icons.circle_outlined,
                                size: 14,
                                color: Colors.amberAccent,
                              ),
                              Text(
                                s.tracked
                                    ? '${s.id} · ${s.speedKt.round()} kt'
                                    : '${s.id} · new',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(blurRadius: 3, color: Colors.black),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final m in _c.mesos)
                      Marker(
                        point: LatLng(m.lat, m.lon),
                        width: 74,
                        height: 40,
                        child: GestureDetector(
                          onTap: () => _showMesoSheet(m),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                m.tvs ? Icons.warning : Icons.rotate_right,
                                size: 20,
                                color: m.tvs
                                    ? Colors.redAccent
                                    : Colors.pinkAccent,
                              ),
                              Text(
                                m.tvs ? 'TVS' : 'MESO ${m.rank}',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: m.tvs
                                      ? Colors.redAccent
                                      : Colors.pinkAccent,
                                  shadows: const [
                                    Shadow(blurRadius: 3, color: Colors.black),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              MarkerLayer(
                markers: [
                  for (final s in nexradSites)
                    if (!s.isTdwr)
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 12,
                        height: 12,
                        child: GestureDetector(
                          onTap: () => _c.selectSite(s, moveMap: true),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: s.icao == _c.site.icao
                                  ? seedColor
                                  : Colors.white24,
                              border: Border.all(color: Colors.black45),
                            ),
                          ),
                        ),
                      ),
                  if (_c.myLocation != null)
                    Marker(
                      point: _c.myLocation!,
                      width: 16,
                      height: 16,
                      child: const Icon(
                        Icons.my_location,
                        size: 16,
                        color: Color(0xFF64B5F6),
                      ),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    '${_c.basemap.attribution} · NOAA/NWS'
                    '${_c.lightning.usesBlitzortung ? ' · lightning © Blitzortung.org' : ''}',
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
          SafeArea(
            child: Column(
              children: [
                _topBar(frame),
                const Spacer(),
                if (_c.futureEnabled) _futureSlider(),
                if (_c.cursorEnabled &&
                    _c.cursorPos != null &&
                    _c.cursorSample != null)
                  _cursorReadout(),
                if (_c.measurePts.length == 2) _measureReadout(),
                if (_c.sampleText != null)
                  _pill(
                    border: Colors.white24,
                    child: Text(
                      _c.sampleText!,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                _bottomBar(frame),
              ],
            ),
          ),
          // Same edge, same toggle. A classified field gets a list of
          // classes rather than a colour scale: the scale would be labelled
          // with class ids, which are not a quantity and mean nothing to
          // read off. The colours are the NWS's own, not our 3D
          // classifier's, because this is their product on screen.
          if (_c.showKey &&
              (_c.product.short == 'HCA' || _c.keyScale != null))
            SafeArea(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _c.product.short == 'HCA'
                      ? const HydroLegend(classes: nwsHydrometeorClasses)
                      : ColorKey(
                          scale: _c.keyScale!,
                          rangeFolded: _c.product.short.contains('VEL') ||
                              _c.product.short.contains('SRM'),
                        ),
                ),
              ),
            ),
          if (_c.loading)
            const Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: 52),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
        ],
      ),
    );
  }

  /// The rounded dark readout pills above the bottom bar.
  Widget _pill({required Widget child, required Color border}) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xE610141A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: child,
      );

  Widget _futureSlider() => Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xCC10141A),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.fast_forward,
                size: 16, color: Colors.lightGreenAccent),
            const SizedBox(width: 6),
            Text(
              _c.futureMinutes == 0
                  ? 'now'
                  : '+${_c.futureMinutes.round()} min',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Expanded(
              child: Slider(
                value: _c.futureMinutes,
                max: 60,
                divisions: 12,
                onChanged: _c.setFutureMinutes,
                onChangeEnd: (_) => _c.commitFutureMinutes(),
              ),
            ),
            const Text(
              'forecast',
              style: TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
      );

  Widget _cursorReadout() {
    final c = _c.cursorSample!;
    final value = c.rangeFolded
        ? 'RF'
        : c.value == null
            ? '—'
            : '${c.value!.toStringAsFixed(1)} ${c.unit}'.trim();
    // Range and heading come from the cursor's actual position so they
    // always agree with the ring; the sample supplies the value and the
    // sweep's elevation.
    final site = _c.cursorSite;
    final (km, brg) = site == null
        ? (c.distanceKm, c.azimuthDeg)
        : distanceBearing(site, _c.cursorPos!);
    final kft = beamHeightM(km * 1000, c.elevationDeg) * 3.28084 / 1000.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xE610141A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.amberAccent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_c.cursorPinned) ...[
            const Icon(Icons.push_pin, size: 13, color: Colors.amberAccent),
            const SizedBox(width: 5),
          ],
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.amberAccent,
            ),
          ),
          const SizedBox(width: 12),
          // Flexible so the range/heading/height line wraps on a narrow
          // screen instead of running off the pill.
          Flexible(
            child: Text(
              '${km.toStringAsFixed(1)} km '
              '(${(km * 0.621371).toStringAsFixed(1)} mi)'
              '  ·  ${brg.round()}°'
              '  ·  ${kft.toStringAsFixed(1)} kft'
              '  @ ${c.elevationDeg.toStringAsFixed(1)}°',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _measureReadout() {
    final (d, b) = distanceBearing(_c.measurePts[0], _c.measurePts[1]);
    return _pill(
      border: Colors.cyanAccent,
      child: Text(
        '${d.toStringAsFixed(1)} km  '
        '(${(d * 0.621371).toStringAsFixed(1)} mi)  ·  '
        '${b.round()}°',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _topBar(DisplayFrame? frame) {
    final age = _c.frameAge;
    // Status on the left, buttons on the right. [ToolBar] keeps them on one
    // line when there is room and stacks them when there isn't — in portrait
    // on a phone the buttons alone are wider than the screen.
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xB310141A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ToolBar(
        status: [
          Text(
            _c.product.isMrms ? 'CONUS' : _c.site.icao,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          Text(
            '${_c.product.short}'
            '${frame != null && _c.product.hasTilts ? ' ${frame.meta.elevationDeg.toStringAsFixed(1)}°' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          if (_c.historyTime != null)
            _badge(
              Colors.indigo.shade700,
              'REPLAY ${DateFormat('MMM d HH:mm').format(_c.historyTime!)}',
            ),
          if (_c.stale && _c.historyTime == null && age != null)
            _badge(Colors.orange.shade900, '${ageLabel(age)} old'),
        ],
        actions: [
          if (_c.alertError != null)
            Tooltip(
              message: 'Alerts: ${_c.alertError}',
              child: const Icon(
                Icons.gpp_maybe,
                size: 18,
                color: Colors.orangeAccent,
              ),
            ),
          if (_c.error != null)
            Tooltip(
              message: _c.error!,
              child: const Icon(
                Icons.error_outline,
                size: 18,
                color: Colors.orangeAccent,
              ),
            ),
          PopupMenuButton<LightningSource>(
            tooltip: 'Lightning source',
            icon: Icon(
              Icons.bolt,
              size: 20,
              color: _c.showLightning ? Colors.yellowAccent : Colors.white38,
            ),
            onSelected: _c.setLightning,
            itemBuilder: (context) => [
              for (final (src, label) in const [
                (LightningSource.off, 'Off'),
                (LightningSource.blitzortung, 'Blitzortung (ground network)'),
                (LightningSource.glm, 'GOES GLM (satellite)'),
                (LightningSource.both, 'Both'),
              ])
                CheckedPopupMenuItem(
                  value: src,
                  checked: _c.lightning == src,
                  child: Text(label),
                ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '3D volume view',
            onPressed: _open3D,
            icon: const Icon(
              Icons.view_in_ar,
              size: 19,
              color: Colors.white70,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Future radar (on-device forecast)',
            onPressed: _c.toggleFuture,
            icon: Icon(
              Icons.fast_forward,
              size: 20,
              color:
                  _c.futureEnabled ? Colors.lightGreenAccent : Colors.white38,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Storm tracks',
            onPressed: _c.toggleTracks,
            icon: Icon(
              Icons.timeline,
              size: 20,
              color:
                  _c.tracksEnabled ? Colors.lightGreenAccent : Colors.white38,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Severe weather layers',
            icon: Icon(
              Icons.warning_amber,
              size: 20,
              // Lit when anything beyond the default warnings layer is on.
              color: (_c.showOutlook ||
                      _c.showReports ||
                      _c.alertLayers.length > 1 ||
                      !_c.alertLayers.contains(AlertCategory.warning))
                  ? Colors.amberAccent
                  : Colors.white70,
            ),
            onSelected: (v) {
              switch (v) {
                case 'outlook':
                  _c.toggleOutlook();
                case 'reports':
                  _c.toggleReports();
                case 'list':
                  _showAlertList();
                default:
                  _c.toggleAlertCategory(
                    AlertCategory.values.firstWhere(
                      (c) => c.name == v,
                      orElse: () => AlertCategory.warning,
                    ),
                  );
              }
            },
            itemBuilder: (context) => [
              for (final c in AlertCategory.values)
                CheckedPopupMenuItem(
                  value: c.name,
                  checked: _c.alertLayers.contains(c),
                  child: Text(c.label),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'list',
                child: Text('All active alerts (${_c.alerts.length})'),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'outlook',
                checked: _c.showOutlook,
                child: const Text('SPC convective outlook'),
              ),
              CheckedPopupMenuItem(
                value: 'reports',
                checked: _c.showReports,
                child: const Text("Today's storm reports"),
              ),
            ],
          ),
          PopupMenuButton<Basemap>(
            tooltip: 'Basemap',
            icon: const Icon(Icons.layers, size: 20, color: Colors.white70),
            onSelected: _c.setBasemap,
            itemBuilder: (context) => [
              for (final b in basemaps)
                CheckedPopupMenuItem(
                  value: b,
                  checked: b == _c.basemap,
                  child: Text(b.label),
                ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'My location',
            onPressed: _c.goToMyLocation,
            icon: const Icon(
              Icons.my_location,
              size: 19,
              color: Colors.white70,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Aiming cursor — hover to read, tap to pin',
            onPressed: _c.toggleCursor,
            icon: Icon(
              Icons.ads_click,
              size: 20,
              color: _c.cursorEnabled ? Colors.amberAccent : Colors.white38,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              switch (v) {
                case 'history':
                  _pickHistory();
                case 'snapshot':
                  _c.saveCurrentSnapshot();
                case 'measure':
                  _c.toggleMeasuring();
                case 'key':
                  _c.toggleColorKey();
                case 'sounding':
                  _openSounding();
                case 'palette_reset':
                  _c.applyPalette('');
                default:
                  if (v.startsWith('pal:')) _c.applyPalette(v.substring(4));
              }
            },
            itemBuilder: (context) {
              final pals = () {
                try {
                  return listPalettes();
                } catch (_) {
                  return <File>[];
                }
              }();
              return [
                PopupMenuItem(
                  value: 'history',
                  child: Text(
                    _c.historyTime == null
                        ? 'Replay a past storm…'
                        : 'Return to live',
                  ),
                ),
                CheckedPopupMenuItem(
                  value: 'measure',
                  checked: _c.measuring,
                  child: const Text('Measure distance'),
                ),
                CheckedPopupMenuItem(
                  value: 'key',
                  checked: _c.showKey,
                  child: const Text('Color key'),
                ),
                const PopupMenuItem(
                  value: 'sounding',
                  child: Text('Upper-air sounding…'),
                ),
                const PopupMenuItem(
                  value: 'snapshot',
                  child: Text('Save snapshot'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  enabled: false,
                  height: 28,
                  child: Text(
                    'COLOR TABLES',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
                for (final f in pals)
                  PopupMenuItem(
                    value: 'pal:${f.path}',
                    child: Text(f.uri.pathSegments.last),
                  ),
                if (pals.isEmpty)
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      'drop .pal files in\n${paletteDir().path}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'palette_reset',
                  child: Text('Built-in colors'),
                ),
              ];
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Reload',
            onPressed: _c.loading ? null : _c.loadFrames,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _badge(Color color, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
      );

  Widget _bottomBar(DisplayFrame? frame) {
    final ts = frame == null
        ? '—'
        : DateFormat('MMM d HH:mm').format(frame.time.toLocal());

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xB310141A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ToolBar(
        status: [
          if (_c.frames.length > 1)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: _c.togglePlaying,
              icon:
                  Icon(_c.playing ? Icons.pause : Icons.play_arrow, size: 20),
            ),
          PopupMenuButton<int>(
            tooltip: 'Animation frames',
            onSelected: _c.setFrameCount,
            itemBuilder: (context) => [
              for (final n in const [1, 4, 8, 12])
                CheckedPopupMenuItem(
                  value: n,
                  checked: _c.frameCount == n,
                  child: Text(n == 1 ? 'Latest only' : '$n frames'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.burst_mode, size: 18, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    _c.frames.isEmpty
                        ? '${_c.frameCount}'
                        : '${_c.shownFrame + 1}/${_c.frames.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          Text(ts, style: const TextStyle(fontSize: 12)),
        ],
        actions: [
          if (_c.product.hasTilts) ...[
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                for (var t = 0; t < 4; t++)
                  ButtonSegment(
                    value: t,
                    label:
                        Text('${t + 1}', style: const TextStyle(fontSize: 11)),
                  ),
              ],
              selected: {_c.tilt},
              onSelectionChanged: (sel) => _c.setTilt(sel.first),
            ),
            const SizedBox(width: 6),
          ],
          PopupMenuButton<Product>(
            tooltip: 'Product',
            onSelected: _c.setProduct,
            itemBuilder: (context) => [
              _productItem(mrmsProduct, badge: 'MRMS'),
              const PopupMenuDivider(),
              _productHeading('LEVEL 3'),
              for (final p in l3Products) _productItem(p),
              const PopupMenuDivider(),
              _productHeading('DERIVED · ON-DEVICE'),
              for (final p in derivedProducts) _productItem(p),
              const PopupMenuDivider(),
              _productHeading('LEVEL 2 · SUPER-RES VOLUME'),
              for (final p in l2Products) _productItem(p),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_c.product.short, style: const TextStyle(fontSize: 12)),
                  const Icon(Icons.arrow_drop_up, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<Product> _productItem(Product p, {String? badge}) =>
      PopupMenuItem(
        value: p,
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                badge ?? p.short.replaceFirst('L2 ', ''),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
            ),
            Text(p.label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );

  PopupMenuItem<Product> _productHeading(String text) => PopupMenuItem(
        enabled: false,
        height: 28,
        child: Text(
          text,
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
      );

  // ------------------------------------------------------------- sheets ----

  /// Detail for one mesocyclone.
  void _showMesoSheet(MesoHit m) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: mapBackground,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.tvs
                    ? 'Tornado vortex signature'
                    : 'Mesocyclone · rank ${m.rank}',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: m.tvs ? Colors.redAccent : Colors.pinkAccent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Circulation ${m.id}'
                '${m.stormId.isEmpty ? '' : ' · storm ${m.stormId}'}',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 4),
              Text(
                'Peak rotational velocity ${m.maxRvKt.round()} kt'
                '${m.msi >= 0 ? '  ·  strength index ${m.msi}' : ''}',
                style: const TextStyle(color: Colors.white70),
              ),
              if (m.motion.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motion ${m.motion} (deg/kt, as the product reports it)',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                m.tvs
                    ? 'The NWS tornado vortex signature algorithm fired on '
                        'this circulation. That is a radar signature, not a '
                        'confirmed tornado, and it is not a warning — always '
                        'follow official NWS warnings.'
                    : 'Detected by the NWS Mesocyclone Detection Algorithm, '
                        'which requires rotation to persist through depth and '
                        'between volumes. Rank 5 and above is treated as '
                        'significant.',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  void _showTrackSheet(StormTrack s) {
    final dir = ((s.headingDeg / 22.5).round() % 16);
    const pts = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: mapBackground,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Storm cell ${s.id}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.tracked
                    ? 'Moving toward ${pts[dir]} '
                        '(${s.headingDeg.round()}°) at '
                        '${s.speedKt.round()} kt'
                    : 'The NWS has no movement solution for this cell yet, '
                        'so it has no track.',
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
              const SizedBox(height: 6),
              if (s.tracked && s.errorNm > 0)
                Text(
                  'NWS forecast track error: ${s.errorNm} NM',
                  style: const TextStyle(color: Colors.white70),
                ),
              if (s.tracked) ...[
                const SizedBox(height: 10),
                const Text(
                  'Positions are the NWS forecast, which assumes the cell '
                  'keeps its current speed and direction. Storms turn, split '
                  'and decay; treat the far end of the track as a hint.',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Every active alert, grouped by category. This is the only place the
  /// county-issued ones show up at all, since they have no polygon to draw.
  void _showAlertList() {
    final byCat = <AlertCategory, List<WeatherAlert>>{};
    for (final a in _c.alerts) {
      byCat.putIfAbsent(a.category, () => []).add(a);
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.25,
        maxChildSize: 0.95,
        builder: (context, controller) {
          if (_c.alerts.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nothing active right now.'),
              ),
            );
          }
          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              for (final c in AlertCategory.values) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                  child: Text(
                    '${c.label.toUpperCase()}  ·  ${(byCat[c] ?? const []).length}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Say so explicitly. A missing heading looks the same as a
                // broken feature, and "no watches right now" is a real and
                // common answer.
                if ((byCat[c] ?? const []).isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 4, 4),
                    child: Text('none active',
                        style:
                            TextStyle(fontSize: 12, color: Colors.white38)),
                  ),
                  for (final a in byCat[c] ?? const <WeatherAlert>[])
                    ListTile(
                      dense: true,
                      leading: Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: a.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(a.event,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                        a.areaDesc.isEmpty ? a.headline : a.areaDesc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      // Only the drawn ones can be zoomed to.
                      trailing: a.hasPolygon
                          ? const Icon(Icons.map, size: 16)
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (a.hasPolygon) _zoomToAlert(a);
                        _showAlertSheet(a);
                      },
                    ),
                ],
            ],
          );
        },
      ),
    );
  }

  void _showAlertSheet(WeatherAlert alert) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.45,
        minChildSize: 0.2,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: alert.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    alert.event,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (alert.headline.isNotEmpty)
              Text(
                alert.headline,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
            const SizedBox(height: 12),
            Text(
              alert.description,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
