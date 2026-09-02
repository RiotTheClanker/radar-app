/// One radar view: a map, a product, and the overlays that go on it.
///
/// This is everything that used to be `_RadarScreenState` minus the chrome.
/// The split is what makes multiple panes possible at all: a pane owns its
/// site, product, tilt and decoded frames, while the things that are true of
/// the whole workspace — alerts, lightning, the animation clock, the replay
/// time — live in [WorkspaceState] and are read from there.
///
/// The workspace drives a pane through its [RadarPaneState], reached with a
/// [GlobalKey]. That is a blunter instrument than a callback interface, but
/// the toolbar genuinely does need to reach into whichever pane has focus and
/// change its product, and routing every one of those through the parent's
/// [State] would be the same coupling with more indirection.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import '../data/hydrometeor.dart';
import '../data/identity.dart';
import '../data/lightning.dart';
import '../data/nexrad_sites.g.dart';
import '../src/rust/api/radar.dart';
import 'alert_sheets.dart';
import 'color_key.dart';
import 'geo.dart';
import 'hydro_legend.dart';
import '../state/pane_controller.dart';
import 'pane_models.dart';
import 'volume3d_screen.dart';
import 'workspace_state.dart';
import 'wx_theme.dart';


class RadarPane extends StatefulWidget {
  const RadarPane({
    super.key,
    required this.paneId,
    required this.shared,
    required this.initialSite,
    required this.initialProduct,
    this.initialTilt = 0,
    required this.focused,
    required this.onFocus,
    required this.onChanged,
    required this.onCameraMoved,
    required this.onSitePicked,
    required this.onIsolateToggled,
    required this.showHeader,
    required this.autoLoad,
    this.initialCenter,
    this.initialZoom,
  });

  /// Stable index within the workspace, used to key this pane's contribution
  /// to the shared animation clock.
  final int paneId;
  final WorkspaceState shared;
  final NexradSite initialSite;
  final RadarProduct initialProduct;

  /// The cut a pane opens on. Panes added by growing the layout inherit the
  /// group's, so they arrive matching rather than at 0.5 while the rest are
  /// somewhere else.
  final int initialTilt;

  /// Whether the toolbar's actions currently land here.
  final bool focused;
  final VoidCallback onFocus;

  /// Something the toolbar displays changed — product, tilt, site, frame
  /// time, load state.
  final VoidCallback onChanged;

  /// A user gesture moved this pane's map. The workspace decides whether to
  /// pass that on to the others.
  final void Function(int paneId, LatLng center, double zoom) onCameraMoved;

  /// A radar site marker on this pane's map was tapped. Routed up rather
  /// than applied here so it goes through the same site linking as the
  /// toolbar's picker — tapping a site on the map is the same request as
  /// choosing it from the list, and should reach the same panes.
  final void Function(NexradSite) onSitePicked;

  /// The pane's link button was pressed. Routed up because rejoining the
  /// group means adopting the group's site, tilt and view, and only the
  /// workspace knows what the rest of the group is doing.
  final VoidCallback onIsolateToggled;

  /// Panes label themselves once there is more than one of them; with a
  /// single pane the toolbar already says all of this.
  final bool showHeader;

  /// Whether this pane may fetch yet. Held false until the workspace has
  /// finished working out where we are, so a cold start does not fetch the
  /// fallback site's data and then immediately throw it away — which for a
  /// Level 2 product is a wasted 10 MB per pane.
  final bool autoLoad;

  /// Where a newly built pane opens. Panes added by growing the layout are
  /// born looking at what the others are looking at, rather than jumping
  /// there a frame later.
  final LatLng? initialCenter;
  final double? initialZoom;

  @override
  State<RadarPane> createState() => RadarPaneState();
}

/// Draws one pane. Everything it draws lives in [PaneController]; this class
/// owns only the things that need a `BuildContext` or the map camera — the
/// map itself, the pane's measured size, the chrome, the sheets and the
/// marker caches.
///
/// The public methods below are the workspace's handle on a pane (it holds
/// `GlobalKey<RadarPaneState>`), and forward straight to the controller.
class RadarPaneState extends State<RadarPane> {
  /// Height of the per-pane label strip.
  static const _headerH = 22.0;

  /// Ceiling on lightning glyphs drawn at once, per pane.
  static const _maxStrikeMarkers = 1500;

  /// Below this the key stops being a legend and starts being the view: in a
  /// 2x2 on a phone each pane is about 180x310, and a full-height key eats a
  /// third of the width it is supposed to be explaining. Short panes are the
  /// harder case — a landscape phone gives each pane ~155px, less than the
  /// key's natural height, so it overflowed its own pane.
  static const _keyMinPaneWidth = 210.0;
  static const _keyMinPaneHeight = 200.0;

  /// Chrome the key has to share the pane with: label strip, the key's own
  /// padding and unit caption, and a margin so it does not touch the edges.
  static const _keyChrome = 76.0;

  late final PaneController _c = PaneController(
    paneId: widget.paneId,
    shared: widget.shared,
    site: widget.initialSite,
    product: widget.initialProduct,
    tilt: widget.initialTilt,
  );

  final _mapController = MapController();
  bool _mapReady = false;

  final LayerHitNotifier<WeatherAlert> _alertHit = ValueNotifier(null);

  /// The radar site dots. Two hundred-odd markers that only change when the
  /// selected site does, so they are built once rather than on every rebuild
  /// — and shared state notifies often enough for that to matter.
  List<Marker>? _siteMarkers;
  String? _siteMarkersFor;

  Timer? _viewDebounce;

  /// The pane's own size, in logical pixels. Viewport re-rendering used to
  /// read this off [MediaQuery], which was the same thing while the map was
  /// the whole window. In a 2x2 it is four times too many pixels.
  Size _paneSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _c
      ..viewport = _readViewport
      ..onMoveMap = _moveCamera
      // Read through `widget` each time rather than captured once, so the
      // callback stays correct across a parent rebuild.
      ..onChanged = (() => widget.onChanged())
      ..addListener(_onPane);
    widget.shared.addListener(_onShared);
    // Deferred: [PaneController.loadFrames] notifies before its first await,
    // and rebuilding while the State is still being constructed is an error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.autoLoad) unawaited(_c.loadFrames());
    });
  }

  @override
  void didUpdateWidget(RadarPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The workspace has settled on a site; this is the first honest load.
    if (widget.autoLoad &&
        !oldWidget.autoLoad &&
        _c.frameCountLoaded == 0 &&
        !_c.loading) {
      unawaited(_c.loadFrames());
    }
  }

  @override
  void dispose() {
    widget.shared.removeListener(_onShared);
    _c.removeListener(_onPane);
    // Also cancels the pane's own ticker and drops it from the shared clock.
    _c.dispose();
    _viewDebounce?.cancel();
    _alertHit.dispose();
    _mapController.dispose();
    super.dispose();
  }

  /// Shared state moved. Alerts, lightning, the clock and the basemap all
  /// just repaint; anything needing a refetch is reloaded by the workspace,
  /// which is the only side that knows a reload is warranted.
  void _onShared() {
    if (mounted) setState(() {});
  }

  /// This pane's own state moved.
  void _onPane() {
    if (mounted) setState(() {});
  }

  /// What the controller can see of the map. Null until the map is attached
  /// and the pane has been measured, which is the controller's cue to skip
  /// viewport work rather than guess at a size.
  /// An unmeasured pane still reports. [PaneController] reads `zoom` off this
  /// for the site-change recentre and the mosaic hand-over, neither of which
  /// cares how wide the pane is, and `_viewBox` already refuses to render at
  /// a `pixelWidth` of zero, so a width guard here would be both redundant
  /// and reaching into decisions it has no part in.
  ///
  /// Nothing is broken today — `_mapReady` is set in `onMapReady`, which
  /// cannot fire before the `LayoutBuilder` has set `_paneSize` — so this is
  /// a trap removed rather than a bug fixed.
  PaneViewport? _readViewport() {
    if (!mounted || !_mapReady) return null;
    try {
      final cam = _mapController.camera;
      final vis = cam.visibleBounds;
      return PaneViewport(
        north: vis.north,
        south: vis.south,
        east: vis.east,
        west: vis.west,
        zoom: cam.zoom,
        pixelWidth: _paneSize.width * MediaQuery.of(context).devicePixelRatio,
      );
    } catch (_) {
      return null;
    }
  }

  void _moveCamera(LatLng center, double zoom) {
    if (_mapReady) _mapController.move(center, zoom);
  }

  // ------------------------------------------------- the pane's handle ----
  // The workspace drives panes through these; they are the controller's API
  // with the camera-shaped parts kept here, where the camera is.

  PaneController get controller => _c;
  WorkspaceState get shared => widget.shared;
  MapController get mapController => _mapController;

  NexradSite get site => _c.site;
  RadarProduct get product => _c.product;
  int get tilt => _c.tilt;
  bool get loading => _c.loading;
  String? get error => _c.error;
  bool get isolated => _c.isolated;
  bool get cursorOn => _c.cursorOn;
  bool get tracksOn => _c.tracksOn;
  bool get futureOn => _c.futureOn;
  bool get measuringOn => _c.measuringOn;
  int get frameCountLoaded => _c.frameCountLoaded;
  int get loopLength => _c.loopLength;
  int get frameIndex => _c.frameIndex;
  bool get playing => _c.playing;
  int get frameCount => _c.frameCount;
  DateTime? get frameTime => _c.frameTime;
  Duration? get dataAge => _c.dataAge;
  bool get isStale => _c.isStale;
  double? get elevationDeg => _c.elevationDeg;

  void togglePlay() => _c.togglePlay();
  void step(int delta) => _c.step(delta);
  void setFrameCount(int n) => _c.setFrameCount(n);
  void setProduct(RadarProduct p) => _c.setProduct(p);
  void setTilt(int t) => _c.setTilt(t);
  void selectSite(NexradSite s, {bool moveMap = false}) =>
      _c.selectSite(s, moveMap: moveMap);
  void toggleCursor() => _c.toggleCursor();
  void toggleTracks() => _c.toggleTracks();
  void syncTo({NexradSite? site, int? tilt}) =>
      _c.syncTo(site: site, tilt: tilt);
  void toggleIsolate() => _c.toggleIsolate();
  void toggleMeasure() => _c.toggleMeasure();
  void toggleFuture() => _c.toggleFuture();
  Future<void> loadFrames() => _c.loadFrames();
  Future<void> refreshForNewData() => _c.refreshForNewData();
  String? saveFrameSnapshot() => _c.saveFrameSnapshot();

  /// Where this pane is looking, or null before the map is attached.
  ({LatLng center, double zoom})? get cameraOrNull {
    if (!_mapReady) return null;
    final c = _mapController.camera;
    return (center: c.center, zoom: c.zoom);
  }

  /// Move this pane's camera without echoing the move back to the workspace.
  /// Used for view linking; guarded so a pane that is already there does not
  /// start a ping-pong of moves between panes.
  ///
  /// A locked pane ignores this. [force] is for the explicit "take me there"
  /// commands aimed at this pane in particular — a button the user just
  /// pressed has to do something, even when the pane is locked.
  void applyCamera(LatLng center, double zoom, {bool force = false}) {
    if (!mounted || !_mapReady) return;
    if (_c.isolated && !force) return;
    final cam = _mapController.camera;
    const eps = 1e-7;
    if ((cam.center.latitude - center.latitude).abs() < eps &&
        (cam.center.longitude - center.longitude).abs() < eps &&
        (cam.zoom - zoom).abs() < eps) {
      return;
    }
    _mapController.move(center, zoom);
  }

  void frameBounds(LatLngBounds bounds, {bool force = false}) {
    if (!_mapReady) return;
    if (_c.isolated && !force) return;
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
    );
  }

  /// Open the 3D volume view on the Level 2 volume for this site, at the
  /// moment currently being shown. The controller fetches; navigating is the
  /// widget's half of the job.
  Future<void> open3D() async {
    final bytes = await _c.prepareVolume();
    if (bytes == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Volume3DScreen(
          volumeBytes: bytes,
          siteId: _c.site.icao,
          basemapUrl: widget.shared.basemap.url,
        ),
      ),
    );
  }

  /// A tap with the cursor active either releases the pin (when it landed on
  /// the pin itself) or re-aims. The 24 px hit test needs the camera, which
  /// is why it lives here rather than in the controller.
  void _onCursorTap(LatLng p) {
    final existing = _c.cursorPos;
    if (_c.cursorPinned && existing != null && _mapReady) {
      final cam = _mapController.camera;
      final d =
          (cam.latLngToScreenOffset(existing) - cam.latLngToScreenOffset(p))
              .distance;
      if (d < 24) {
        _c.unpinCursor();
        return;
      }
    }
    _c.aimCursor(p, fromTap: true);
  }

  /// Zoomed out past a single radar's useful range, hand over to the
  /// national mosaic.
  ///
  /// Labelled panes means there is more than one of them. Asking the
  /// workspace which layout it wants would be the wrong question: what
  /// matters is how many panes are actually on screen, which is what the
  /// label strip already tracks.
  void _maybeSwitchMosaic() => _c.maybeSwitchMosaic(multiPane: widget.showHeader);

  // ------------------------------------------------------ chrome sizing ----

  /// Whether there is room for a colour key in this pane at all. A pane too
  /// small for one is better off showing the weather.
  bool get _keyFits =>
      widget.shared.showKey &&
      (_paneSize == Size.zero ||
          (_paneSize.width >= _keyMinPaneWidth &&
              _paneSize.height >= _keyMinPaneHeight));

  /// The key shrinks to fit before it disappears, so a merely snug pane keeps
  /// its legend rather than losing it at a cliff edge.
  double get _keyBarHeight {
    if (_paneSize == Size.zero) return 168;
    final room = _paneSize.height - _headerH - _keyChrome;
    return room.clamp(70.0, 168.0);
  }

  static String _ageLabel(Duration age) =>
      age.inHours >= 1 ? '${age.inHours}h' : '${age.inMinutes}m';


  /// Colour for a strike by age: bright white-yellow when fresh, fading to
  /// dim orange over twenty minutes.
  Color _strikeColor(Strike s) {
    final ageMin = DateTime.now().toUtc().difference(s.time).inSeconds / 60.0;
    final t = (ageMin / 20.0).clamp(0.0, 1.0);
    return Color.lerp(
      const Color(0xFFFFF59D),
      const Color(0x66E65100),
      t,
    )!;
  }

  /// Strikes drawn as bolts rather than dots — a circle on a radar map reads
  /// as a range ring or a storm cell, and lightning is the one layer whose
  /// shape everyone already knows.
  ///
  /// Culled to the visible bounds and capped: twenty minutes of an active
  /// squall line is thousands of strikes, and a marker apiece across four
  /// panes is the most expensive thing on screen.
  List<Marker> _strikeMarkers(WorkspaceState shared) {
    if (!_mapReady) return const [];
    final visible = _mapController.camera.visibleBounds;
    final out = <Marker>[];
    // Newest first, so the cap drops the faintest rather than the freshest.
    for (var i = shared.strikes.length - 1; i >= 0; i--) {
      final s = shared.strikes[i];
      if (!visible.contains(s.pos)) continue;
      final fresh = DateTime.now().toUtc().difference(s.time).inMinutes < 2;
      out.add(
        Marker(
          point: s.pos,
          width: 14,
          height: 14,
          child: IgnorePointer(
            child: Icon(
              Icons.bolt,
              size: fresh ? 14 : 11,
              color: _strikeColor(s),
            ),
          ),
        ),
      );
      if (out.length >= _maxStrikeMarkers) break;
    }
    return out;
  }

  // ----------------------------------------------------------------- ui ----

  @override
  Widget build(BuildContext context) {
    final shared = widget.shared;
    final frame = _c.displayFrame;

    return LayoutBuilder(builder: (context, constraints) {
      // Recording the pane's size here is what lets viewport re-renders ask
      // for the right number of pixels. A changed size also invalidates the
      // current render, so kick off a fresh one.
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size != _paneSize) {
        final had = _paneSize;
        _paneSize = size;
        if (had != Size.zero) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_c.renderViewport());
          });
        }
      }

      return RepaintBoundary(
        child: Listener(
        // Click to focus, deliberately not hover. Focus decides which pane
        // the toolbar acts on, and following the pointer meant that reaching
        // for a control retargeted it on the way: crossing a neighbouring
        // pane to get to the bar handed that pane the focus, so the setting
        // landed somewhere you were only passing over.
        onPointerDown: (_) {
          if (!widget.focused) widget.onFocus();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: widget.focused && widget.showHeader ? Wx.accent : Wx.line,
            ),
          ),
          child: Stack(
              children: [
                Positioned.fill(child: _map(shared, frame)),
                if (widget.showHeader)
                  Positioned(top: 0, left: 0, right: 0, child: _header(shared)),
                if (_c.loading)
                  Positioned(
                    // Under the label strip rather than through it.
                    top: widget.showHeader ? _headerH : 0,
                    left: 0,
                    right: 0,
                    child: const LinearProgressIndicator(minHeight: 2),
                  ),
                // Same edge, same toggle. A classified field gets a list of
                // classes rather than a colour scale: the scale would be
                // labelled with class ids, which are not a quantity and mean
                // nothing to read off. The colours are the NWS's own, not our
                // 3D classifier's, because this is their product on screen.
                if (_keyFits && (_c.product.short == 'HCA' || _c.keyScale != null))
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _c.product.short == 'HCA'
                          ? const HydroLegend(classes: nwsHydrometeorClasses)
                          : ColorKey(
                              scale: _c.keyScale!,
                              barHeight: _keyBarHeight,
                              rangeFolded: _c.product.short.contains('VEL') ||
                                  _c.product.short.contains('SRM'),
                            ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _readouts(),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// The pane's own label: which radar, which product, what time. Without
  /// this a 2x2 is four anonymous maps.
  Widget _header(WorkspaceState shared) {
    final t = frameTime;
    final el = elevationDeg;
    final stale = isStale;

    return Container(
      height: _headerH,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: Wx.bg1.withValues(alpha: 0.88),
        border: Border(
          // Lit edge on the strip that carries this pane's own controls —
          // easier to pick out across a 2x2 than a hairline outline.
          top: BorderSide(
            color: widget.focused ? Wx.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Text(
            _c.product.isMrms ? 'CONUS' : _c.site.icao,
            style: Wx.label.copyWith(
              fontWeight: FontWeight.w700,
              color: widget.focused ? Wx.accent : Wx.text,
            ),
          ),
          const SizedBox(width: 6),
          Text(_c.product.bareShort, style: Wx.labelDim),
          if (el != null) ...[
            const SizedBox(width: 5),
            Text('${el.toStringAsFixed(1)}°', style: Wx.labelDim),
          ],
          const Spacer(),
          if (stale)
            Tooltip(
              // Says whose fault it is. The app is showing everything it has
              // been given; the radar has not published since this scan.
              message: 'No new scan for '
                  '${_ageLabel(dataAge ?? Duration.zero)} — the radar or the '
                  'NOAA feed is behind, not the app',
              child: const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.cloud_off, size: 12, color: Wx.danger),
              ),
            ),
          if (_c.error != null)
            Tooltip(
              message: _c.error!,
              child: const Padding(
                padding: EdgeInsets.only(right: 5),
                child: Icon(Icons.error_outline, size: 12, color: Wx.warn),
              ),
            ),
          Text(
            t == null ? '—' : DateFormat('HH:mm').format(t.toLocal()),
            style: Wx.mono.copyWith(
              color: stale ? Wx.danger : Wx.textDim,
              fontWeight: stale ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          // Trailing edge, where a window's controls live. Lit when engaged
          // so a glance across the grid says which panes are out of the
          // group. Same link/link-off vocabulary as the workspace's Link
          // menu, because this is the per-pane half of the same idea.
          WxButton(
            icon: _c.isolated ? Icons.link_off : Icons.link,
            tooltip: _c.isolated
                ? 'Isolated — this pane ignores the others and does not move '
                    'them. Click to rejoin the linked panes.'
                : 'Isolate this pane from the linked panes',
            height: _headerH,
            dense: true,
            color: _c.isolated ? Wx.accent : Wx.textFaint,
            onTap: widget.onIsolateToggled,
          ),
        ],
      ),
    );
  }

  Widget _map(WorkspaceState shared, DisplayFrame? frame) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: widget.initialCenter ?? LatLng(_c.site.lat, _c.site.lon),
        initialZoom: widget.initialZoom ?? 7,
        minZoom: 3,
        maxZoom: 15,
        onMapReady: () => _mapReady = true,
        onTap: (tapPos, latlng) {
          if (_c.measuringOn) _c.addMeasurePoint(latlng);
          if (_c.cursorOn) _onCursorTap(latlng);
        },
        onPointerHover: (event, latlng) {
          if (_c.cursorOn) unawaited(_c.aimCursor(latlng));
        },
        onLongPress: (tapPos, latlng) => unawaited(_c.inspect(latlng)),
        // Pinch-zoom and drag, but no accidental two-finger rotation:
        // a twisted radar map is disorienting and hard to undo on touch.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapEvent: (evt) {
          _maybeSwitchMosaic();
          // Only a real gesture propagates to the linked panes. Echoing a
          // move that arrived from another pane is how view linking turns
          // into an infinite loop between two maps. A locked pane says
          // nothing either — it is out of the group in both directions.
          if (!_c.isolated &&
              evt.source != MapEventSource.mapController &&
              evt.source != MapEventSource.fitCamera) {
            widget.onCameraMoved(
              widget.paneId,
              evt.camera.center,
              evt.camera.zoom,
            );
          }
          _viewDebounce?.cancel();
          // Only the radar image depends on the viewport. Storm tracks are
          // positioned by azimuth and range from the site, so panning and
          // zooming cannot change where they are — and refetching on every
          // gesture would be network for nothing.
          _viewDebounce = Timer(
            const Duration(milliseconds: 350),
            () => unawaited(_c.renderViewport()),
          );
        },
        backgroundColor: Wx.bg0,
      ),
      children: [
        TileLayer(
          urlTemplate: shared.basemap.url,
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
        if (shared.showOutlook)
          PolygonLayer(
            polygons: [
              for (final a in shared.outlook)
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
              showAlertSheet(context, hit.hitValues.first);
            }
          },
          child: PolygonLayer(
            hitNotifier: _alertHit,
            polygons: [
              for (final a in shared.alerts)
                if (shared.alertLayers.contains(a.category))
                  for (final ring in a.polygons)
                    Polygon(
                      points: ring,
                      hitValue: a,
                      // Watches and advisories sit under the warnings
                      // rather than competing with them.
                      color: a.color.withValues(
                        alpha:
                            a.category == AlertCategory.warning ? 0.12 : 0.07,
                      ),
                      borderColor: a.color.withValues(
                        alpha:
                            a.category == AlertCategory.warning ? 1.0 : 0.75,
                      ),
                      borderStrokeWidth:
                          a.category == AlertCategory.warning ? 2 : 1.2,
                    ),
            ],
          ),
        ),
        if (shared.showLightning)
          MarkerLayer(markers: _strikeMarkers(shared)),
        if (shared.showReports)
          MarkerLayer(
            markers: [
              for (final r in shared.reports)
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
        if (_c.cursorOn && _c.cursorPos != null && _c.cursorSite != null) ...[
          PolylineLayer(
            polylines: [
              Polyline(
                // Geometric, so the ring passes exactly through the
                // crosshair at every bearing — even outside radar coverage,
                // where there is no sample to take a distance from.
                points: geodesicRing(
                  _c.cursorSite!,
                  distanceBearing(_c.cursorSite!, _c.cursorPos!).$1,
                ),
                color: Wx.warn.withValues(alpha: 0.85),
                strokeWidth: 1.5,
              ),
              Polyline(
                points: [_c.cursorSite!, _c.cursorPos!],
                color: Wx.warn.withValues(alpha: 0.9),
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
                    color: Wx.warn,
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
                color: Wx.accent,
                strokeWidth: 2,
              ),
            ],
          ),
        if (_c.measuringOn)
          MarkerLayer(
            markers: [
              for (final p in _c.measurePts)
                Marker(
                  point: p,
                  width: 12,
                  height: 12,
                  child: const Icon(Icons.circle, size: 10, color: Wx.accent),
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
        if (_c.tracksOn) ...[
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
                        shadows: [Shadow(blurRadius: 3, color: Colors.black)],
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
                          color: Wx.warn,
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
                          color: m.tvs ? Wx.danger : Colors.pinkAccent,
                        ),
                        Text(
                          m.tvs ? 'TVS' : 'MESO ${m.rank}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: m.tvs ? Wx.danger : Colors.pinkAccent,
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
        MarkerLayer(markers: _sites()),
        if (shared.myLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: shared.myLocation!,
                width: 14,
                height: 14,
                child: const Icon(
                  Icons.my_location,
                  size: 14,
                  color: Color(0xFF64B5F6),
                ),
              ),
            ],
          ),
      ],
    );
  }

  List<Marker> _sites() {
    final cached = _siteMarkers;
    if (cached != null && _siteMarkersFor == _c.site.icao) return cached;
    final built = [
      for (final s in nexradSites)
        if (!s.isTdwr)
          Marker(
            point: LatLng(s.lat, s.lon),
            width: 10,
            height: 10,
            child: GestureDetector(
              onTap: () => widget.onSitePicked(s),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.icao == _c.site.icao ? Wx.accent : Colors.white24,
                  border: Border.all(color: Colors.black45),
                ),
              ),
            ),
          ),
    ];
    _siteMarkers = built;
    _siteMarkersFor = _c.site.icao;
    return built;
  }

  /// Tool readouts, stacked at the foot of the pane. Each only appears while
  /// its tool is on, so an idle pane is all map.
  Widget _readouts() {
    final rows = <Widget>[];

    if (_c.futureOn) {
      rows.add(
        Container(
          height: 30,
          padding: const EdgeInsets.only(left: 8, right: 4),
          color: Wx.bg1.withValues(alpha: 0.92),
          child: Row(
            children: [
              const Icon(Icons.fast_forward, size: 13, color: Wx.good),
              const SizedBox(width: 6),
              Text(
                _c.futureMinutes == 0 ? 'now' : '+${_c.futureMinutes.round()} min',
                style: Wx.mono.copyWith(color: Wx.good),
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
              const Text('forecast', style: Wx.labelDim),
            ],
          ),
        ),
      );
    }

    if (_c.cursorOn && _c.cursorPos != null && _c.cursorSample != null) {
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
      rows.add(
        _readoutBar(
          accent: Wx.warn,
          leading: _c.cursorPinned ? Icons.push_pin : Icons.ads_click,
          value: value,
          detail: '${km.toStringAsFixed(1)} km '
              '(${(km * 0.621371).toStringAsFixed(1)} mi)'
              '  ·  ${brg.round()}°'
              '  ·  ${kft.toStringAsFixed(1)} kft'
              '  @ ${c.elevationDeg.toStringAsFixed(1)}°',
        ),
      );
    }

    if (_c.measurePts.length == 2) {
      final (d, b) = distanceBearing(_c.measurePts[0], _c.measurePts[1]);
      rows.add(
        _readoutBar(
          accent: Wx.accent,
          leading: Icons.straighten,
          value: '${d.toStringAsFixed(1)} km',
          detail: '(${(d * 0.621371).toStringAsFixed(1)} mi)  ·  ${b.round()}°',
        ),
      );
    }

    final sample = _c.sampleText;
    if (sample != null) {
      rows.add(
        _readoutBar(
          accent: Wx.textDim,
          leading: Icons.center_focus_weak,
          value: '',
          detail: sample,
        ),
      );
    }

    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _readoutBar({
    required Color accent,
    required IconData leading,
    required String value,
    required String detail,
  }) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Wx.bg1.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: accent.withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          Icon(leading, size: 12, color: accent),
          const SizedBox(width: 6),
          if (value.isNotEmpty) ...[
            Text(
              value,
              style: Wx.mono.copyWith(color: accent, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              detail,
              overflow: TextOverflow.ellipsis,
              style: Wx.mono,
            ),
          ),
        ],
      ),
    );
  }

  /// Detail for one storm cell.
  void _showTrackSheet(StormTrack s) {
    final dir = ((s.headingDeg / 22.5).round() % 16);
    const pts = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    showModalBottomSheet<void>(
      context: context,
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
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Wx.text,
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
                style: const TextStyle(
                  color: Wx.text,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              if (s.tracked && s.errorNm > 0)
                Text(
                  'NWS forecast track error: ${s.errorNm} NM',
                  style: const TextStyle(color: Wx.textDim, fontSize: 12.5),
                ),
              if (s.tracked) ...[
                const SizedBox(height: 10),
                const Text(
                  'Positions are the NWS forecast, which assumes the cell '
                  'keeps its current speed and direction. Storms turn, split '
                  'and decay; treat the far end of the track as a hint.',
                  style: TextStyle(
                    color: Wx.textFaint,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Detail for one mesocyclone.
  void _showMesoSheet(MesoHit m) {
    showModalBottomSheet<void>(
      context: context,
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
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: m.tvs ? Wx.danger : Colors.pinkAccent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Circulation ${m.id}'
                '${m.stormId.isEmpty ? '' : ' · storm ${m.stormId}'}',
                style: const TextStyle(color: Wx.text, fontSize: 12.5),
              ),
              const SizedBox(height: 4),
              Text(
                'Peak rotational velocity ${m.maxRvKt.round()} kt'
                '${m.msi >= 0 ? '  ·  strength index ${m.msi}' : ''}',
                style: const TextStyle(color: Wx.text, fontSize: 12.5),
              ),
              if (m.motion.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motion ${m.motion} (deg/kt, as the product reports it)',
                  style: const TextStyle(color: Wx.text, fontSize: 12.5),
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
                  color: Wx.textFaint,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
