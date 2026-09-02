/// Map tile sources offered under the radar.
library;

/// One basemap choice.
///
/// [attribution] is not decoration: CARTO, OpenStreetMap, Esri and
/// OpenTopoMap all require visible credit under their terms of use. Whatever
/// the UI looks like, the string for the active basemap has to stay on
/// screen.
class Basemap {
  final String label;
  final String url;
  final String attribution;
  const Basemap(this.label, this.url, this.attribution);
}

/// The basemap the app opens on. Dark by default: the app is used at night
/// during severe weather, and a bright basemap both washes out the radar
/// colours and wrecks the user's night vision. Declared before the list and
/// referenced from it so there is exactly one copy of the URL.
const defaultBasemap = Basemap(
  'Dark',
  'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
  '© OpenStreetMap © CARTO',
);

const basemaps = [
  defaultBasemap,
  Basemap(
    'OpenStreetMap',
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap contributors',
  ),
  Basemap(
    'Satellite',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Imagery © Esri',
  ),
  Basemap(
    'Topographic',
    'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap © OpenTopoMap (CC-BY-SA)',
  ),
];
