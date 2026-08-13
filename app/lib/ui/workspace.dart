/// The workspace: chrome around one to four radar panes.
///
/// The layout is three docked strips and a grid — a menu bar, a product bar,
/// the panes, and a status bar. Nothing floats over the map except the colour
/// key and the tool readouts, which belong to a pane rather than to the app.
///
/// Toolbar actions land on the *focused* pane, the one last pressed in and
/// marked with an accent border once there is more than one. Map movement and
/// radar site optionally apply to every pane at once, since the usual reason
/// to open four panes is one storm in four products.
///
/// Linkage runs one way: site follows view. Panes that are not panning
/// together are not looking at the same weather, so moving them onto a
/// different radar is as likely to throw away someone's view as to help —
/// see [WorkspaceState.propagatesSite]. A pane can also drop out of the group
/// on its own, which takes its view and its site with it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import '../data/identity.dart';
import '../data/locate.dart';
import '../data/nexrad_sites.g.dart';
import '../data/sounding_fetcher.dart';
import '../data/user_files.dart';
import '../src/rust/api/radar.dart';
import 'alert_sheets.dart';
import 'pane_models.dart';
import 'radar_pane.dart';
import 'sounding_screen.dart';
import 'workspace_state.dart';
import 'wx_theme.dart';

class RadarWorkspace extends StatefulWidget {
  const RadarWorkspace({super.key});

  @override
  State<RadarWorkspace> createState() => _RadarWorkspaceState();
}

class _RadarWorkspaceState extends State<RadarWorkspace> {
  final _shared = WorkspaceState();

  /// One key per possible pane, made once and kept. Shrinking the layout
  /// disposes the panes it drops; growing it back builds fresh ones.
  final _paneKeys = List.generate(
    PaneLayout.quad.count,
    (_) => GlobalKey<RadarPaneState>(),
  );

  /// What each pane opens on. Only read when a pane is first built, after
  /// which the pane owns its own site and product.
  late List<NexradSite> _seedSites;
  late List<RadarProduct> _seedProducts;

  int _focused = 0;

  /// False until [_startup] has decided which radar we are near. Panes hold
  /// their first fetch until then.
  bool _seedResolved = false;

  /// Last camera any pane reported, so a pane added by growing the layout
  /// opens where the others already are.
  LatLng? _lastCenter;
  double? _lastZoom;

  @override
  void initState() {
    super.initState();
    final start = nexradSites.firstWhere((s) => s.icao == 'KTLX');
    _seedSites = List.filled(PaneLayout.quad.count, start);
    _seedProducts = List.of(panelPreset);
    _shared.addListener(_onShared);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_startup()));
  }

  @override
  void dispose() {
    _shared.removeListener(_onShared);
    _shared.dispose();
    super.dispose();
  }

  void _onShared() {
    if (mounted) setState(() {});
  }

  /// Find where we are and tune to the nearest radar. GPS if permission is
  /// already granted, IP geolocation otherwise; no prompt here, that belongs
  /// to the "my location" button. Falls back to the default site silently.
  Future<void> _startup() async {
    final loc = await locate(askPermission: false);
    if (!mounted) return;
    if (loc != null) {
      _shared.setMyLocation(loc);
      final nearest = _nearestSite(loc);
      _seedSites = List.filled(PaneLayout.quad.count, nearest);
      _lastCenter = loc;
      _lastZoom = 7;
      for (final p in _livePanes) {
        p.selectSite(nearest, moveMap: false);
        p.applyCamera(loc, 7);
      }
    }
    // Releases the panes to fetch, whether or not we found a position — a
    // failed lookup means the fallback site is the answer, not that we wait.
    setState(() => _seedResolved = true);
  }

  // -------------------------------------------------------------- panes ----

  RadarPaneState? get _active {
    final i = _focused < _paneKeys.length ? _focused : 0;
    return _paneKeys[i].currentState;
  }

  Iterable<RadarPaneState> get _livePanes sync* {
    for (var i = 0; i < _effective.count; i++) {
      final s = _paneKeys[i].currentState;
      if (s != null) yield s;
    }
  }

  /// A pane changed something the chrome displays. Deferred when a build is
  /// already under way — a pane can report a change from inside a map event
  /// that fires during layout, and setState is not allowed there.
  void _onPaneChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _onCameraMoved(int paneId, LatLng center, double zoom) {
    // Recorded even when unlinked, so a pane added later still opens on the
    // storm rather than on whatever its site's default view was.
    _lastCenter = center;
    _lastZoom = zoom;
    if (!_shared.linkViews) return;
    for (var i = 0; i < _effective.count; i++) {
      if (i == paneId) continue;
      _paneKeys[i].currentState?.applyCamera(center, zoom);
    }
  }

  void _setLayout(PaneLayout l) {
    if (_focused >= l.count) _focused = 0;
    // Take the current view from a pane that already exists, so panes about
    // to be built inherit it rather than the seed site's default framing.
    final cam = _active?.cameraOrNull;
    if (cam != null) {
      _lastCenter = cam.center;
      _lastZoom = cam.zoom;
    }
    _shared.setLayout(l);
  }

  void _reloadAll() {
    for (final p in _livePanes) {
      unawaited(p.loadFrames());
    }
  }

  /// What a pane being built for the first time opens on.
  ///
  /// Taken from whatever the group is already looking at, not from the seed
  /// captured at startup: going from two panes to four used to add the new
  /// pair on the radar the app launched with, however far the first two had
  /// since been moved. [_seedSites] is only the fallback for the very first
  /// build, before any pane exists to ask.
  NexradSite _seedSiteFor(int id) {
    for (final p in _livePanes) {
      if (!p.isolated) return p.site;
    }
    return _seedSites[id];
  }

  /// Likewise for the elevation cut, which linked panes share.
  int _seedTilt() {
    for (final p in _livePanes) {
      if (!p.isolated) return p.tilt;
    }
    return 0;
  }

  /// The panes a command issued in [from] should also reach.
  ///
  /// Empty when [from] is isolated, which is the half that was missing: an
  /// isolated pane refused to follow the others' radar changes but still
  /// pushed its own onto them. Isolation cuts both directions or it is not
  /// isolation.
  Iterable<RadarPaneState> _groupWith(RadarPaneState? from, {
    required bool linked,
  }) sync* {
    if (!WorkspaceState.reachesGroup(
      sourceIsolated: from?.isolated ?? false,
      linked: linked,
    )) {
      return;
    }
    for (final p in _livePanes) {
      if (identical(p, from) || p.isolated) continue;
      yield p;
    }
  }

  /// The elevation cut, applied to the focused pane and its group.
  void _setTilt(int t) {
    final focused = _active;
    focused?.setTilt(t);
    for (final p in _groupWith(focused, linked: _shared.propagatesTilt)) {
      p.setTilt(t);
    }
  }

  /// Bring a pane that has just rejoined the group back into step with it.
  ///
  /// Without this, re-linking looked like it had not worked: the pane kept
  /// whatever site, tilt and view it had drifted to while it was out, and
  /// only fell in line once you changed something. Nothing visibly happened
  /// at the moment you asked for the panes to be linked again.
  void _syncIntoGroup(RadarPaneState pane) {
    RadarPaneState? anchor;
    for (final p in _livePanes) {
      if (!identical(p, pane) && !p.isolated) {
        anchor = p;
        break;
      }
    }
    if (anchor == null) return; // nothing to be in step with
    pane.syncTo(
      site: _shared.propagatesSite ? anchor.site : null,
      tilt: _shared.propagatesTilt ? anchor.tilt : null,
    );
    if (!_shared.linkViews) return;
    final cam = anchor.cameraOrNull;
    if (cam != null) pane.applyCamera(cam.center, cam.zoom, force: true);
  }

  /// Pull the whole group onto the focused pane, for when linking is switched
  /// back on rather than a single pane rejoining.
  void _syncGroupToFocused() {
    var anchor = _active;
    if (anchor == null || anchor.isolated) {
      anchor = null;
      for (final p in _livePanes) {
        if (!p.isolated) {
          anchor = p;
          break;
        }
      }
    }
    if (anchor == null) return;
    final cam = anchor.cameraOrNull;
    for (final p in _groupWith(anchor, linked: true)) {
      p.syncTo(
        site: _shared.propagatesSite ? anchor.site : null,
        tilt: _shared.propagatesTilt ? anchor.tilt : null,
      );
      if (_shared.linkViews && cam != null) {
        p.applyCamera(cam.center, cam.zoom, force: true);
      }
    }
  }

  /// A pane's own link button. The toggle happens here rather than in the
  /// pane so rejoining can immediately put it back in step.
  void _toggleIsolate(RadarPaneState pane) {
    pane.toggleIsolate();
    if (!pane.isolated) _syncIntoGroup(pane);
  }

  void _setSite(NexradSite s) {
    // The pane being worked in always changes: picking a radar is an
    // explicit command, so it lands even on an isolated pane.
    final focused = _active;
    focused?.selectSite(s, moveMap: true);
    for (final p in _groupWith(focused, linked: _shared.propagatesSite)) {
      p.selectSite(s, moveMap: true);
    }
  }

  NexradSite _nearestSite(LatLng p) {
    NexradSite best = nexradSites.first;
    double bestD = double.infinity;
    for (final s in nexradSites) {
      if (s.isTdwr) continue; // TDWR products come in a later phase
      final d = _dist2(p.latitude, p.longitude, s.lat, s.lon);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  // Squared equirectangular distance — plenty for "which site is closest".
  double _dist2(double lat1, double lon1, double lat2, double lon2) {
    final dy = lat1 - lat2;
    final dx = (lon1 - lon2) * math.cos(lat1 * math.pi / 180.0);
    return dy * dy + dx * dx;
  }

  // ------------------------------------------------------------ actions ----

  Future<void> _goToMyLocation() async {
    // Always re-ask rather than reusing the startup fix: the button is what
    // triggers the permission prompt, and a stale position is the thing the
    // user is trying to correct.
    final result = await locateDetailed();
    final loc = result.position;
    if (!mounted) return;
    if (loc == null) {
      // Silence here reads as a dead button, so say what went wrong.
      _toast(result.message);
      return;
    }
    _shared.setMyLocation(loc);
    // The pane you are working in goes there even if it is isolated — you
    // just pressed the button. The rest follow only if that pane is part of
    // the group and the views are linked.
    final zoom = result.precise ? 8.0 : 7.0;
    final focused = _active;
    focused?.applyCamera(loc, zoom, force: true);
    for (final p in _groupWith(focused, linked: _shared.linkViews)) {
      p.applyCamera(loc, zoom);
    }
    final nearest = _nearestSite(loc);
    if (focused != null && nearest.icao != focused.site.icao) {
      _setSite(nearest);
    }
  }

  /// Jump the whole workspace to a past moment (or back to live).
  Future<void> _pickHistory() async {
    if (_shared.historyTime != null) {
      _shared.setHistoryTime(null);
      _reloadAll();
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
    _shared.setHistoryTime(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
    _reloadAll();
  }

  /// Apply a .pal file (or clear back to the built-ins).
  Future<void> _applyPalette(String path) async {
    try {
      if (path.isEmpty) {
        await resetPalettes();
      } else {
        final kind = await installPalette(text: File(path).readAsStringSync());
        if (!mounted) return;
        _toast('Palette applied to $kind');
      }
      _shared.bumpPalette();
      _reloadAll();
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  /// Open the sounding for the launch site nearest whatever we are looking
  /// at — the radar site, or the user's own position if we have one.
  void _openSounding() {
    final site = _active?.site;
    final here = _shared.myLocation ??
        (site == null ? const LatLng(35.3, -97.3) : LatLng(site.lat, site.lon));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SoundingScreen(
          site: nearestRaobSite(here.latitude, here.longitude),
        ),
      ),
    );
  }

  void _snapshot() {
    final path = _active?.saveFrameSnapshot();
    _toast(path == null ? 'Nothing to save yet' : 'Saved $path');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Wx.bg2,
          content: Text(message, style: Wx.label),
        ),
      );
  }

  Future<void> _pickSite() async {
    final chosen = await showDialog<NexradSite>(
      context: context,
      builder: (_) => _SitePicker(current: _active?.site),
    );
    if (chosen != null) _setSite(chosen);
  }

  void _zoomToAlert(WeatherAlert a) {
    final b = alertBounds(a);
    if (b == null) return;
    // Picking an alert out of the list is a "show me this" command, so the
    // focused pane goes there regardless of its isolation.
    final focused = _active;
    focused?.frameBounds(b, force: true);
    for (final p in _groupWith(focused, linked: _shared.linkViews)) {
      p.frameBounds(b);
    }
  }

  // ----------------------------------------------------------------- ui ----

  /// Whether there is room to spell the menus out. Below this the labels are
  /// dropped for icons alone: on a phone "Layers" and "Tools" together cost
  /// about 140 of 360 points, which is what pushed the layout switcher — the
  /// whole reason multi-panel exists — off the edge and behind a scroll.
  static const _wideChrome = 520.0;

  bool _wide = true;

  /// What is actually on screen. [WorkspaceState.layout] stays as whatever
  /// the user chose, so a layout that does not fit the current window is
  /// restored rather than forgotten once there is room for it again.
  PaneLayout _effective = PaneLayout.single;
  List<PaneLayout> _available = PaneLayout.values;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Wx.bg0,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          _wide = constraints.maxWidth >= _wideChrome;

          // What the panes actually get, once the three strips have taken
          // their share.
          final gridW = constraints.maxWidth;
          final gridH = constraints.maxHeight - Wx.barH * 2 - Wx.statusH;
          _available = PaneLayout.availableIn(gridW, gridH);
          _effective = PaneLayout.bestFor(_shared.layout, gridW, gridH);
          // Focus can be left pointing at a pane the new layout does not
          // have — picking four on a phone renders two.
          if (_focused >= _effective.count) _focused = 0;

          return Column(
            children: [
              _menuBar(),
              _productBar(),
              Expanded(child: _grid()),
              _statusBar(),
            ],
          );
        }),
      ),
    );
  }

  Widget _grid() {
    final layout = _effective;
    final multi = layout.count > 1;
    var id = 0;
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              for (var r = 0; r < layout.rows; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var c = 0; c < layout.cols; c++)
                        Expanded(child: _pane(id++, multi)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // Bounded on both sides: right-anchored alone, the text lays out at
        // its natural width and runs off a phone-width pane rather than
        // ellipsising. Attribution has to stay legible, so it gets the width
        // it needs and truncates only past that.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Align(
              alignment: Alignment.bottomRight,
              child: _attribution(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pane(int id, bool multi) {
    return RadarPane(
      key: _paneKeys[id],
      paneId: id,
      shared: _shared,
      initialSite: _seedSiteFor(id),
      initialTilt: _seedTilt(),
      initialProduct: _seedProducts[id],
      focused: multi && _focused == id,
      showHeader: multi,
      autoLoad: _seedResolved,
      initialCenter: _lastCenter,
      initialZoom: _lastZoom,
      onFocus: () => setState(() => _focused = id),
      onChanged: _onPaneChanged,
      onCameraMoved: _onCameraMoved,
      onSitePicked: _setSite,
      onIsolateToggled: () {
        final p = _paneKeys[id].currentState;
        if (p != null) _toggleIsolate(p);
      },
    );
  }

  // The top strip: what we are looking at, and how it is arranged.
  Widget _menuBar() {
    final active = _active;
    final site = active?.site;
    final linked = _shared.linkSite || _shared.linkViews;
    final isolatedCount = _livePanes.where((p) => p.isolated).length;

    return WxBar(
      leading: [
        WxButton(
          label: site == null ? '—' : site.icao,
          icon: Icons.cell_tower,
          tooltip: site == null
              ? 'Radar site'
              : '${site.name}, ${site.state} — change radar site',
          onTap: _pickSite,
          minWidth: _wide ? 74 : 0,
        ),
        const WxSep(),
        // Layout. Four flat buttons rather than a menu: switching between
        // one and four panes is the whole feature, and burying it one click
        // deep would make it feel like a setting.
        for (final l in _available)
          WxButton(
            icon: _layoutIcon(l),
            tooltip: l.label,
            dense: true,
            active: _effective == l,
            onTap: () => _setLayout(l),
          ),
        if (_effective != PaneLayout.single) ...[
          const SizedBox(width: 2),
          WxMenu<String>(
            icon: linked ? Icons.link : Icons.link_off,
            label: _wide ? 'Link' : null,
            tooltip: 'What the panes share',
            active: linked,
            onSelected: (v) {
              switch (v) {
                case 'views':
                  _shared.setLinkViews(!_shared.linkViews);
                  if (_shared.linkViews) _syncGroupToFocused();
                case 'site':
                  _shared.setLinkSite(!_shared.linkSite);
                  if (_shared.propagatesSite) _syncGroupToFocused();
                case 'rejoin':
                  for (final p in _livePanes.toList()) {
                    if (p.isolated) _toggleIsolate(p);
                  }
              }
            },
            itemBuilder: (_) => [
              wxMenuItem(
                value: 'views',
                label: 'Pan and zoom together',
                checked: _shared.linkViews,
              ),
              // Subordinate to the views: with panes panning separately a
              // shared radar has nothing to keep them on, so this says so
              // rather than sitting there ticked and doing nothing.
              wxMenuItem(
                value: 'site',
                label: _shared.linkViews
                    ? 'Same radar site'
                    : 'Same radar site (needs linked views)',
                checked: _shared.propagatesSite,
                enabled: _shared.linkViews,
              ),
              // A pane isolated and forgotten looks like a pane that stopped
              // working, so the way back is offered where the linking lives
              // rather than only on the pane itself.
              if (isolatedCount > 0) ...[
                const PopupMenuDivider(),
                wxMenuItem(
                  value: 'rejoin',
                  label: isolatedCount == 1
                      ? 'Rejoin 1 isolated pane'
                      : 'Rejoin $isolatedCount isolated panes',
                  showCheck: true,
                  checked: false,
                ),
              ],
            ],
          ),
        ],
      ],
      trailing: [
        _layersMenu(),
        _toolsMenu(),
        WxMenu<Basemap>(
          icon: Icons.map_outlined,
          tooltip: 'Basemap',
          caret: false,
          onSelected: _shared.setBasemap,
          itemBuilder: (_) => [
            for (final b in basemaps)
              wxMenuItem(
                value: b,
                label: b.label,
                checked: b == _shared.basemap,
              ),
          ],
        ),
        WxButton(
          icon: Icons.my_location,
          tooltip: 'My location',
          dense: true,
          onTap: () => unawaited(_goToMyLocation()),
        ),
        WxButton(
          icon: Icons.refresh,
          tooltip: 'Reload',
          dense: true,
          onTap: (active?.loading ?? false) ? null : _reloadAll,
        ),
      ],
    );
  }

  IconData _layoutIcon(PaneLayout l) => switch (l) {
        PaneLayout.single => Icons.crop_square,
        PaneLayout.twoAcross => Icons.vertical_split,
        PaneLayout.twoDown => Icons.horizontal_split,
        PaneLayout.quad => Icons.grid_view,
      };

  // The second strip: the products, on screen rather than behind a menu.
  Widget _productBar() {
    final active = _active;
    final product = active?.product;
    final onQuickBar =
        product != null && quickProducts.any((p) => identical(p, product));

    return WxBar(
      leading: [
        for (final p in quickProducts)
          WxButton(
            label: p.bareShort,
            tooltip: p.label,
            active: product != null && identical(p, product),
            onTap: active == null ? null : () => active.setProduct(p),
          ),
        WxMenu<RadarProduct>(
          label: onQuickBar ? 'More' : (product?.bareShort ?? 'More'),
          tooltip: 'All products',
          active: !onQuickBar,
          onSelected: (p) => active?.setProduct(p),
          itemBuilder: (_) => [
            wxMenuItem(
              value: mrmsProduct,
              label: mrmsProduct.label,
              code: 'MRMS',
              checked: product != null && identical(mrmsProduct, product),
            ),
            const PopupMenuDivider(),
            wxMenuHeading<RadarProduct>('LEVEL 3'),
            for (final p in l3Products)
              wxMenuItem(
                value: p,
                label: p.label,
                code: p.short,
                checked: product != null && identical(p, product),
              ),
            const PopupMenuDivider(),
            wxMenuHeading<RadarProduct>('DERIVED · ON-DEVICE'),
            for (final p in derivedProducts)
              wxMenuItem(
                value: p,
                label: p.label,
                code: p.short,
                checked: product != null && identical(p, product),
              ),
            const PopupMenuDivider(),
            wxMenuHeading<RadarProduct>('LEVEL 2 · SUPER-RES VOLUME'),
            for (final p in l2Products)
              wxMenuItem(
                value: p,
                label: p.label,
                code: p.bareShort,
                checked: product != null && identical(p, product),
              ),
          ],
        ),
        if (product?.hasTilts ?? false) ...[
          const WxSep(),
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Text('TILT', style: Wx.heading),
          ),
          for (var t = 0; t < 4; t++)
            WxButton(
              label: '${t + 1}',
              tooltip: 'Elevation cut ${t + 1}',
              dense: true,
              active: active?.tilt == t,
              onTap: active == null ? null : () => _setTilt(t),
            ),
        ],
      ],
      trailing: [
        // Per-pane tools. They act on the focused pane, which is why they sit
        // here next to the products rather than in the menu bar.
        WxButton(
          icon: Icons.ads_click,
          tooltip: 'Aiming cursor — hover to read, tap to pin',
          dense: true,
          active: active?.cursorOn ?? false,
          onTap: active?.toggleCursor,
        ),
        WxButton(
          icon: Icons.timeline,
          tooltip: 'Storm tracks and mesocyclones',
          dense: true,
          active: active?.tracksOn ?? false,
          onTap: active?.toggleTracks,
        ),
        WxButton(
          icon: Icons.fast_forward,
          tooltip: 'Future radar (on-device forecast)',
          dense: true,
          active: active?.futureOn ?? false,
          onTap: active?.toggleFuture,
        ),
        WxButton(
          icon: Icons.straighten,
          tooltip: 'Measure distance',
          dense: true,
          active: active?.measuringOn ?? false,
          onTap: active?.toggleMeasure,
        ),
        WxButton(
          icon: Icons.view_in_ar,
          tooltip: '3D volume view',
          dense: true,
          onTap: active == null ? null : () => unawaited(active.open3D()),
        ),
      ],
    );
  }

  Widget _layersMenu() {
    final beyondDefault = _shared.showOutlook ||
        _shared.showReports ||
        _shared.alertLayers.length > 1 ||
        !_shared.alertLayers.contains(AlertCategory.warning);

    return WxMenu<String>(
      label: _wide ? 'Layers' : null,
      icon: Icons.layers_outlined,
      tooltip: 'Warnings, outlooks, lightning',
      active: beyondDefault || _shared.showLightning,
      onSelected: (v) {
        switch (v) {
          case 'outlook':
            unawaited(_shared.toggleOutlook());
          case 'reports':
            unawaited(_shared.toggleReports());
          case 'list':
            showAlertList(context, _shared.alerts, onZoom: _zoomToAlert);
          case 'key':
            _shared.toggleKey();
          default:
            if (v.startsWith('lt:')) {
              _shared.setLightning(
                LightningSource.values.firstWhere(
                  (s) => s.name == v.substring(3),
                  orElse: () => LightningSource.off,
                ),
              );
            } else {
              _shared.toggleAlertLayer(
                AlertCategory.values.firstWhere(
                  (c) => c.name == v,
                  orElse: () => AlertCategory.warning,
                ),
              );
            }
        }
      },
      itemBuilder: (_) => [
        wxMenuHeading<String>('NWS ALERTS'),
        for (final c in AlertCategory.values)
          wxMenuItem(
            value: c.name,
            label: c.label,
            checked: _shared.alertLayers.contains(c),
          ),
        wxMenuItem(
          value: 'list',
          label: 'All active alerts (${_shared.alerts.length})…',
          showCheck: true,
          checked: false,
        ),
        const PopupMenuDivider(),
        wxMenuHeading<String>('LIGHTNING'),
        for (final s in LightningSource.values)
          wxMenuItem(
            value: 'lt:${s.name}',
            label: s.label,
            checked: _shared.lightning == s,
          ),
        const PopupMenuDivider(),
        wxMenuHeading<String>('SPC'),
        wxMenuItem(
          value: 'outlook',
          label: 'Convective outlook',
          checked: _shared.showOutlook,
        ),
        wxMenuItem(
          value: 'reports',
          label: "Today's storm reports",
          checked: _shared.showReports,
        ),
        const PopupMenuDivider(),
        wxMenuItem(
          value: 'key',
          label: 'Colour key',
          checked: _shared.showKey,
        ),
      ],
    );
  }

  Widget _toolsMenu() {
    final pals = () {
      try {
        return listPalettes();
      } catch (_) {
        return <File>[];
      }
    }();

    return WxMenu<String>(
      label: _wide ? 'Tools' : null,
      icon: Icons.build_outlined,
      tooltip: 'Replay, snapshots, colour tables',
      active: _shared.historyTime != null,
      onSelected: (v) {
        switch (v) {
          case 'history':
            unawaited(_pickHistory());
          case 'snapshot':
            _snapshot();
          case 'sounding':
            _openSounding();
          case 'palette_reset':
            unawaited(_applyPalette(''));
          default:
            if (v.startsWith('pal:')) unawaited(_applyPalette(v.substring(4)));
        }
      },
      itemBuilder: (_) => [
        wxMenuItem(
          value: 'history',
          label: _shared.historyTime == null
              ? 'Replay a past storm…'
              : 'Return to live',
          checked: _shared.historyTime != null,
        ),
        wxMenuItem(
          value: 'sounding',
          label: 'Upper-air sounding…',
          showCheck: true,
          checked: false,
        ),
        wxMenuItem(
          value: 'snapshot',
          label: 'Save snapshot',
          showCheck: true,
          checked: false,
        ),
        const PopupMenuDivider(),
        wxMenuHeading<String>('COLOUR TABLES'),
        for (final f in pals)
          wxMenuItem(
            value: 'pal:${f.path}',
            label: f.uri.pathSegments.last,
            showCheck: true,
            checked: false,
          ),
        if (pals.isEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 34,
            child: Text(
              'drop .pal files in\n${paletteDir().path}',
              style: Wx.labelDim,
            ),
          ),
        wxMenuItem(
          value: 'palette_reset',
          label: 'Built-in colours',
          showCheck: true,
          checked: false,
        ),
      ],
    );
  }

  // The bottom strip: the animation clock and what the data is.
  Widget _statusBar() {
    final active = _active;
    // An isolated pane runs its own loop, so the transport follows it while
    // it has focus. Without that the play button would be driving panes the
    // user is not looking at and doing nothing to the one they are.
    final solo = (active != null && active.isolated) ? active : null;
    final n = solo?.loopLength ?? _shared.loopLength;
    final idx = n == 0
        ? 0
        : (solo?.frameIndex ?? _shared.frameIndex).clamp(0, n - 1);
    final playing = solo?.playing ?? _shared.playing;
    final count = solo?.frameCount ?? _shared.frameCount;
    final t = active?.frameTime;
    final age = active?.dataAge;
    final stale = active?.isStale ?? false;
    final staleLabel = stale && age != null ? _ageLabel(age) : null;

    return WxBar(
      top: true,
      bottom: false,
      height: Wx.statusH,
      leading: [
        WxButton(
          icon: playing ? Icons.pause : Icons.play_arrow,
          tooltip: solo == null
              ? (playing ? 'Pause' : 'Play loop')
              : (playing
                  ? 'Pause the isolated pane'
                  : 'Play the isolated pane'),
          dense: true,
          height: Wx.statusH,
          active: playing,
          onTap: n < 2 ? null : (solo != null ? solo.togglePlay : _shared.togglePlay),
        ),
        WxButton(
          icon: Icons.chevron_left,
          tooltip: 'Previous frame',
          dense: true,
          height: Wx.statusH,
          onTap: n < 2
              ? null
              : () => solo != null ? solo.step(-1) : _shared.step(-1),
        ),
        WxButton(
          icon: Icons.chevron_right,
          tooltip: 'Next frame',
          dense: true,
          height: Wx.statusH,
          onTap: n < 2
              ? null
              : () => solo != null ? solo.step(1) : _shared.step(1),
        ),
        WxMenu<int>(
          label: n == 0 ? '$count' : '${idx + 1}/$n',
          tooltip: solo == null
              ? 'Loop length'
              : 'Loop length for the isolated pane',
          height: Wx.statusH,
          onSelected: (v) {
            if (solo != null) {
              solo.setFrameCount(v);
            } else if (_shared.setFrameCount(v)) {
              _reloadAll();
            }
          },
          itemBuilder: (_) => [
            for (final v in const [1, 4, 8, 12])
              wxMenuItem(
                value: v,
                label: v == 1 ? 'Latest only' : '$v frames',
                checked: count == v,
              ),
          ],
        ),
        // Says which loop the transport is driving, so a paused group and a
        // running isolated pane are not confusable.
        if (solo != null)
          const Padding(
            padding: EdgeInsets.only(left: 2),
            child: Tooltip(
              message: 'These controls are driving the isolated pane, not '
                  'the linked group',
              child: Icon(Icons.link_off, size: 12, color: Wx.accent),
            ),
          ),
        const WxSep(),
        Text(
          t == null
              ? '—'
              : DateFormat('MMM d  HH:mm').format(t.toLocal()),
          style: Wx.mono.copyWith(
            color: stale ? Wx.danger : Wx.text,
            fontWeight: stale ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        if (_shared.historyTime != null)
          WxChip(
            text: 'REPLAY '
                '${DateFormat('MMM d HH:mm').format(_shared.historyTime!)}',
            color: Wx.accent,
            icon: Icons.history,
          ),
        if (staleLabel != null)
          Tooltip(
            message: 'The radar has published nothing newer. The gap is '
                'upstream at the site or in the NOAA feed.',
            child: WxChip(
              text: 'NO NEW SCAN $staleLabel',
              color: Wx.danger,
              icon: Icons.cloud_off,
            ),
          ),
        if (_shared.alertError != null)
          WxChip(
            text: 'ALERTS',
            color: Wx.warn,
            icon: Icons.gpp_maybe,
          ),
      ],
    );
  }

  /// Tile and data attribution. One copy for the whole grid rather than one
  /// per pane, sat in the corner the map convention puts it in.
  Widget _attribution() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      child: Text(
        '${_shared.basemap.attribution} · NOAA/NWS'
        '${_shared.lightning.usesBlitzortung ? ' · lightning © Blitzortung.org' : ''}',
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 9.5, color: Wx.textFaint),
      ),
    );
  }

  String _ageLabel(Duration age) {
    if (age.inHours >= 1) return '${age.inHours}h';
    return '${age.inMinutes}m';
  }
}

/// Search-and-pick over the NEXRAD list.
///
/// The old UI could only change site by finding its dot on the map, which is
/// fine for the one you are already looking at and hopeless for anywhere
/// else. Matching on id, name and state covers the three ways people know a
/// radar: "KTLX", "Norman", "OK".
class _SitePicker extends StatefulWidget {
  const _SitePicker({this.current});

  final NexradSite? current;

  @override
  State<_SitePicker> createState() => _SitePickerState();
}

class _SitePickerState extends State<_SitePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final matches = [
      for (final s in nexradSites)
        if (!s.isTdwr &&
            (q.isEmpty ||
                s.icao.toLowerCase().contains(q) ||
                s.name.toLowerCase().contains(q) ||
                s.state.toLowerCase() == q))
          s,
    ];

    return Dialog(
      backgroundColor: Wx.bg1,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: Wx.line),
        borderRadius: BorderRadius.zero,
      ),
      child: SizedBox(
        width: 420,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                autofocus: true,
                style: Wx.label,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 16),
                  prefixIconConstraints: BoxConstraints(minWidth: 32),
                  hintText: 'Radar id, city or state',
                  hintStyle: Wx.labelDim,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: Wx.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: Wx.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: Wx.accent),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: matches.isEmpty
                  ? const Center(
                      child: Text('No radar matches that.',
                          style: Wx.labelDim),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemExtent: 40,
                      itemBuilder: (context, i) {
                        final s = matches[i];
                        final on = s.icao == widget.current?.icao;
                        return ListTile(
                          dense: true,
                          selected: on,
                          selectedTileColor: Wx.accentFill,
                          title: Row(
                            children: [
                              SizedBox(
                                width: 52,
                                child: Text(
                                  s.icao,
                                  style: Wx.label.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: on ? Wx.accent : Wx.text,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${s.name}, ${s.state}',
                                  overflow: TextOverflow.ellipsis,
                                  style: Wx.labelDim,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => Navigator.of(context).pop(s),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Text('$appShortName · ${matches.length} radars',
                      style: Wx.labelDim),
                  const Spacer(),
                  WxButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
