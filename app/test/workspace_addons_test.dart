/// What the workspace does with addons once they are loaded: the site list,
/// layer toggles, the theme, and switching an addon off.
///
/// State tests, no widgets — through [WorkspaceState.setAddons], so nothing
/// reads the real config folder.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/data/addons.dart';
import 'package:radar_app/data/radar_source.dart';
import 'package:radar_app/state/pane_controller.dart';
import 'package:radar_app/ui/pane_models.dart';
import 'package:radar_app/ui/workspace_state.dart';
import 'package:radar_app/ui/wx_theme.dart';

Addon _addon() => parseAddon('''
{"id": "club", "name": "Club",
 "sites": [{"id": "XOKC", "lat": 35.4, "lon": -97.6,
            "level2": {"url": "https://e.org/"}},
           {"id": "KTLX", "lat": 35.33, "lon": -97.28,
            "level2": {"url": "https://mirror.e.org/"}}],
 "overlays": [{"id": "box", "type": "geojson",
               "data": {"type": "LineString",
                        "coordinates": [[-98, 35], [-97, 36]]}},
              {"id": "off", "type": "tiles", "visible": false,
               "url": "https://t.e.org/{z}/{x}/{y}.png"}],
 "places": [{"id": "p", "items": [{"lat": 35, "lon": -97}]}],
 "themes": [{"id": "red", "colors": {"accent": "#FF0000"},
             "basemap": "Satellite"}]}
''', path: 'club.json');

void main() {
  late WorkspaceState ws;
  late Addon a;
  setUp(() {
    ws = WorkspaceState();
    a = _addon();
    ws.setAddons([a]);
  });
  tearDown(() => ws.dispose());

  test('addon sites join the radar list, overrides replace', () {
    expect(ws.siteById('XOKC'), isA<AddonSite>());
    final tlx = ws.siteById('KTLX');
    expect(tlx, isA<AddonSite>());
    expect((tlx! as AddonSite).level2!.url, 'https://mirror.e.org/');
    expect(ws.radarSites.where((s) => s.icao == 'KTLX'), hasLength(1));
  });

  test('switching an addon off puts the built-in site back', () {
    final before = ws.siteGeneration;
    ws.setAddonEnabled(a, false);
    expect(ws.siteById('XOKC'), isNull);
    expect(ws.siteById('KTLX'), isNot(isA<AddonSite>()));
    expect(ws.siteGeneration, greaterThan(before),
        reason: 'panes rebind on this');
    expect(ws.overlays, isEmpty);
    expect(ws.placeGroups, isEmpty);
  });

  test('layers start at their own default and toggle', () {
    final box = ws.overlays.first, off = ws.overlays.last;
    expect(ws.overlayOn(box), isTrue);
    expect(ws.overlayOn(off), isFalse);
    ws.toggleOverlay(off);
    expect(ws.overlayOn(off), isTrue);
    final g = ws.placeGroups.single;
    expect(ws.placesOn(g), isTrue);
    ws.togglePlaces(g);
    expect(ws.placesOn(g), isFalse);
  });

  test('an inline GeoJSON overlay needs no network', () async {
    await pumpEventQueue();
    expect(ws.overlayShapes['club/box']!.lines, hasLength(1));
    expect(ws.overlayErrors, isEmpty);
  });

  test('a theme applies its basemap, and lapses with its addon', () {
    final t = ws.themes.single;
    ws.setTheme(t);
    expect(ws.theme?.key, 'club/red');
    expect(ws.basemap.label, 'Satellite');
    ws.setAddonEnabled(a, false);
    expect(ws.theme, isNull,
        reason: 'no stuck colours from an addon that is switched off');
    ws.setAddonEnabled(a, true);
    expect(ws.theme?.key, 'club/red', reason: 'and the choice comes back');
  });

  test('a pane on an addon radar with no Level 3 source says why', () async {
    // XOKC is a new id with only a Level 2 source. Borrowing NOAA's bucket
    // for Level 3 would mean OKC's files — someone else's radar.
    final c = PaneController(
      paneId: 0,
      shared: ws,
      site: ws.siteById('XOKC')!,
      product: productRef,
      tilt: 0,
    );
    addTearDown(c.dispose);
    await c.loadFrames();
    expect(c.frames, isEmpty);
    expect(c.error, contains('no Level 3 source'));
  });

  test('a pane rebinds when its site is re-defined, and only then', () {
    final c = PaneController(
      paneId: 0,
      shared: ws,
      site: ws.siteById('XOKC')!,
      product: productRef,
      tilt: 0,
    );
    addTearDown(c.dispose);
    final other = parseAddon(
      '{"id": "b", "name": "B", "sites": [{"id": "XOKC", "lat": 1, '
      '"lon": 2, "level3": {"url": "https://b.e.org/{product}/"}}]}',
      path: 'b',
    ).sites.single;
    c.rebindSite(other);
    expect(identical(c.site, other), isTrue);
    final unrelated = ws.siteById('KTLX')!;
    c.rebindSite(unrelated);
    expect(c.site.icao, 'XOKC', reason: 'rebinding never changes radar');
  });

  group('the UI palette', () {
    tearDown(() => Wx.apply(WxPalette.standard));

    test('a theme overrides only what it names', () {
      final p = WxPalette.standard.merge(a.themes.single.colors);
      expect(p.accent.toARGB32(), 0xFFFF0000);
      expect(p.bg0, WxPalette.standard.bg0);
    });

    test('applying one tells the app root to repaint', () {
      final gen = wxPaletteGeneration.value;
      final p = WxPalette.standard.merge(a.themes.single.colors);
      Wx.apply(p);
      expect(Wx.accent.toARGB32(), 0xFFFF0000);
      expect(wxPaletteGeneration.value, gen + 1);
      Wx.apply(p);
      expect(wxPaletteGeneration.value, gen + 1,
          reason: 're-applying the same palette is free');
    });
  });
}
