/// State that belongs to the workspace rather than to any one pane.
///
/// Alerts, lightning, the SPC layers, the basemap and the animation clock are
/// all properties of "what we are looking at", not of a single radar view.
/// With one pane that distinction did not matter and everything lived in the
/// screen's [State]. With four it does: four panes each polling api.weather.gov
/// every minute and each holding open a Blitzortung websocket would be four
/// times the network for the same answer, and — worse — four panes stepping
/// their own animation clocks would drift apart, which defeats the point of
/// putting reflectivity and velocity side by side.
///
/// So this owns the shared things once, and panes listen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../data/alerts_fetcher.dart';
import '../data/glm_fetcher.dart';
import '../data/lightning.dart';
import '../data/spc_fetcher.dart';
import 'pane_models.dart';

class WorkspaceState extends ChangeNotifier {
  WorkspaceState() {
    _loadAlerts();
    _alertTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _loadAlerts(),
    );
    _animTimer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => _tick(),
    );
  }

  bool _disposed = false;

  void _ping() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------- alerts ----

  List<WeatherAlert> _alerts = const [];
  List<WeatherAlert> get alerts => _alerts;

  /// Which alert categories go on the map. Warnings are what matters in the
  /// moment; watches cover whole counties for hours and would otherwise wash
  /// the map out, so they start off.
  final Set<AlertCategory> alertLayers = {AlertCategory.warning};

  /// Last alert-fetch failure, surfaced rather than swallowed.
  String? alertError;

  Timer? _alertTimer;

  Future<void> _loadAlerts() async {
    try {
      final alerts = await fetchActiveAlerts();
      if (_disposed) return;
      _alerts = alerts;
      alertError = null;
      _ping();
      await resolveAlertOutlines();
    } catch (e) {
      // Keep the last good set, but say something. Swallowing this silently
      // is how a broken request looked like "there are no warnings".
      if (_disposed) return;
      alertError = e.toString();
      _ping();
    }
  }

  /// Build outlines for the county-issued alerts in whichever categories are
  /// switched on. Only those, because resolving every zone nationwide would
  /// be hundreds of requests for shapes nobody asked to see.
  Future<void> resolveAlertOutlines() async {
    final wanted = [
      for (final a in _alerts)
        if (!a.hasPolygon && alertLayers.contains(a.category)) a,
    ];
    if (wanted.isEmpty) return;
    await resolveZoneOutlines(wanted);
    _ping();
  }

  void toggleAlertLayer(AlertCategory c) {
    if (!alertLayers.remove(c)) alertLayers.add(c);
    _ping();
    unawaited(resolveAlertOutlines());
  }

  Future<void> refreshAlerts() => _loadAlerts();

  // ---------------------------------------------------------------- spc ----

  List<OutlookArea> outlook = const [];
  List<StormReport> reports = const [];
  bool showOutlook = false;
  bool showReports = false;

  Future<void> toggleOutlook() async {
    showOutlook = !showOutlook;
    _ping();
    if (!showOutlook || outlook.isNotEmpty) return;
    try {
      final o = await fetchOutlook();
      if (_disposed) return;
      outlook = o;
      _ping();
    } catch (_) {}
  }

  Future<void> toggleReports() async {
    showReports = !showReports;
    _ping();
    if (!showReports || reports.isNotEmpty) return;
    try {
      final r = await fetchStormReports();
      if (_disposed) return;
      reports = r;
      _ping();
    } catch (_) {}
  }

  // ---------------------------------------------------------- lightning ----

  final _blitz = BlitzortungClient();
  final _glm = GlmClient();
  final List<Strike> strikes = [];
  LightningSource lightning = LightningSource.off;
  StreamSubscription<Strike>? _strikeSub;
  StreamSubscription<Strike>? _glmSub;
  Timer? _strikeTimer;
  bool _strikesDirty = false;

  bool get showLightning => lightning != LightningSource.off;

  void setLightning(LightningSource src) {
    lightning = src;
    _ping();

    if (src.usesBlitzortung) {
      _blitz.start();
      _strikeSub ??= _blitz.strikes.listen((s) {
        strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _blitz.stop();
    }
    if (src.usesGlm) {
      _glm.start();
      _glmSub ??= _glm.strikes.listen((s) {
        strikes.add(s);
        _strikesDirty = true;
      });
    } else {
      _glm.stop();
    }

    if (src != LightningSource.off) {
      // Repaint on a slow tick instead of per strike (tens per second).
      _strikeTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        final cutoff =
            DateTime.now().toUtc().subtract(const Duration(minutes: 20));
        final before = strikes.length;
        strikes.removeWhere((s) => s.time.isBefore(cutoff));
        if (strikes.length > 8000) {
          strikes.removeRange(0, strikes.length - 8000);
        }
        if (_strikesDirty || strikes.length != before) {
          _strikesDirty = false;
          _ping();
        }
      });
    } else {
      _strikeTimer?.cancel();
      _strikeTimer = null;
      strikes.clear();
    }
  }

  // ------------------------------------------------------------- layers ----

  Basemap basemap = basemaps[0];
  bool showKey = true;

  /// Where we are, if we found out. Shared: it is a property of the user, not
  /// of a pane, and every pane draws the same marker for it.
  LatLng? myLocation;

  void setMyLocation(LatLng p) {
    myLocation = p;
    _ping();
  }

  /// Bumped when a `.pal` is imported, so every pane's colour key rebuilds.
  int paletteGeneration = 0;

  void setBasemap(Basemap b) {
    basemap = b;
    _ping();
  }

  void toggleKey() {
    showKey = !showKey;
    _ping();
  }

  void bumpPalette() {
    paletteGeneration++;
    _ping();
  }

  // -------------------------------------------------------------- time ----

  /// Historical replay. Shared, because panes showing the same storm at
  /// different times is never what anyone means.
  DateTime? historyTime;

  void setHistoryTime(DateTime? t) {
    historyTime = t;
    _ping();
  }

  // --------------------------------------------------------- animation ----

  /// The animation clock. Panes clamp this to their own frame list rather
  /// than each running a timer, so reflectivity and velocity stay on the
  /// same volume as the loop plays.
  int frameIndex = 0;
  bool playing = false;

  /// How many frames to load per pane. 1 = just the latest scan (default,
  /// fastest); more enables the loop.
  int frameCount = 1;

  Timer? _animTimer;

  /// How many frames each pane actually managed to load. Products cap out
  /// differently — MRMS at 6, Level 2 at 4 — so the loop runs over the
  /// longest of them and short panes hold on their last frame.
  final Map<int, int> _loaded = {};

  int get loopLength {
    var n = 0;
    for (final v in _loaded.values) {
      if (v > n) n = v;
    }
    return n;
  }

  void reportFrames(int paneId, int n) {
    if (_loaded[paneId] == n) return;
    _loaded[paneId] = n;
    if (frameIndex >= loopLength) frameIndex = loopLength - 1;
    _ping();
  }

  void forgetPane(int paneId) {
    if (_loaded.remove(paneId) != null) _ping();
  }

  void _tick() {
    if (!playing) return;
    final n = loopLength;
    if (n < 2) return;
    // Dwell on the newest frame for a few ticks before looping.
    frameIndex = frameIndex >= n - 1 + 3 ? 0 : frameIndex + 1;
    _ping();
  }

  void togglePlay() {
    playing = !playing;
    _ping();
  }

  void setFrameIndex(int i) {
    final n = loopLength;
    if (n == 0) return;
    frameIndex = i.clamp(0, n - 1);
    playing = false;
    _ping();
  }

  void step(int delta) {
    final n = loopLength;
    if (n == 0) return;
    playing = false;
    frameIndex = (frameIndex.clamp(0, n - 1) + delta) % n;
    if (frameIndex < 0) frameIndex += n;
    _ping();
  }

  /// Set the loop length. Returns true if it changed, meaning panes need to
  /// reload — the caller does that, since only it knows the panes.
  bool setFrameCount(int n) {
    if (frameCount == n) return false;
    frameCount = n;
    playing = n > 1;
    _ping();
    return true;
  }

  // ------------------------------------------------------------- panes ----

  /// Whether panning one pane pans the rest, and whether choosing a radar
  /// site applies to every pane. Both default on: the reason to open four
  /// panes is almost always one storm in four products, and un-linking is
  /// there for the times it isn't.
  bool linkViews = true;
  bool linkSite = true;

  /// Whether a radar picked in one pane should reach the others.
  ///
  /// Site follows the view. Panes that are not panning together are not
  /// looking at the same weather, so dragging them onto a different radar is
  /// as likely to throw away the view someone set up as to help — and a pane
  /// moved to a radar that cannot see where it is pointed shows nothing at
  /// all. Unlinking the views therefore unlinks the sites with them, and
  /// [linkSite] becomes the finer control for the case where the views *are*
  /// linked but each pane should keep its own radar — two radars on one
  /// storm, for comparing coverage.
  bool get propagatesSite => linkViews && linkSite;

  /// Whether the elevation cut is shared. Tied to the views because a tilt is
  /// part of *where* a pane is looking, not what it is measuring: linked
  /// panes comparing reflectivity against velocity have to be cutting the
  /// storm at the same height or the comparison says nothing. The product is
  /// the one thing linked panes are meant to differ on.
  bool get propagatesTilt => linkViews;

  /// Whether a command issued in one pane should reach the rest of the group.
  ///
  /// Isolation is symmetric: a pane out of the group neither follows the
  /// others nor drives them. Getting only half of that gave a control that
  /// looked broken from one side — an isolated pane ignored everyone else's
  /// radar changes but still forced its own onto them.
  static bool reachesGroup({
    required bool sourceIsolated,
    required bool linked,
  }) =>
      linked && !sourceIsolated;

  void setLinkViews(bool v) {
    linkViews = v;
    _ping();
  }

  void setLinkSite(bool v) {
    linkSite = v;
    _ping();
  }

  PaneLayout layout = PaneLayout.single;

  void setLayout(PaneLayout l) {
    layout = l;
    _ping();
  }

  @override
  void dispose() {
    _disposed = true;
    _alertTimer?.cancel();
    _animTimer?.cancel();
    _strikeTimer?.cancel();
    _strikeSub?.cancel();
    _glmSub?.cancel();
    _blitz.stop();
    _glm.stop();
    super.dispose();
  }
}
