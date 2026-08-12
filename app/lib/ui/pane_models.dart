/// What a pane can be showing: the product catalog and the basemaps.
///
/// These used to be private to `main.dart`, which was fine while there was
/// one screen holding both the state and the controls. With the product
/// buttons living on the workspace toolbar and the data living in each pane,
/// both sides need to name the same things.
library;

/// One product on offer in the UI. Level 3 tilted products map to mnemonics
/// like N0B/N1B/N2B/N3B (tilt digit in the middle); Level 2 products carry a
/// moment name and decode full Archive II volumes on-device.
class RadarProduct {
  final String label;
  final String short;
  final String? tiltSuffix;
  final String? fixedCode;
  final String? l2Moment;

  /// Volume-integrated Level 2 products have no tilt dimension.
  final bool l2Volume;

  /// National MRMS mosaic: one grid for the whole country, no radar site.
  final bool isMrms;

  const RadarProduct(
    this.label,
    this.short, {
    this.tiltSuffix,
    this.fixedCode,
    this.l2Moment,
    this.l2Volume = false,
    this.isMrms = false,
  });

  bool get isLevel2 => l2Moment != null;
  bool get hasTilts => tiltSuffix != null || (isLevel2 && !l2Volume);
  String code(int tilt) => fixedCode ?? 'N$tilt$tiltSuffix';

  /// The short code without the `L2 ` prefix, for places that already say
  /// which family they are listing.
  String get bareShort => short.startsWith('L2 ') ? short.substring(3) : short;
}

const mrmsProduct = RadarProduct('National Mosaic', 'MRMS', isMrms: true);

// Named individually rather than reached for by index: a const list cannot be
// indexed in a constant expression, and the presets below need to name these
// exact instances so identity comparisons against them hold.
const productRef = RadarProduct('Reflectivity', 'REF', tiltSuffix: 'B');
const productVel = RadarProduct('Velocity', 'VEL', tiltSuffix: 'G');
const productZdr =
    RadarProduct('Differential Reflectivity', 'ZDR', tiltSuffix: 'X');
const productCc =
    RadarProduct('Correlation Coefficient', 'CC', tiltSuffix: 'C');
const productKdp =
    RadarProduct('Specific Differential Phase', 'KDP', tiltSuffix: 'K');
const productHca =
    RadarProduct('Hydrometeor Classification', 'HCA', tiltSuffix: 'H');
const productStp = RadarProduct('Storm Total Precip', 'STP', fixedCode: 'DTA');

const l3Products = [
  productRef,
  productVel,
  productZdr,
  productCc,
  productKdp,
  productHca,
  productStp,
];

const l2Products = [
  RadarProduct('Reflectivity', 'L2 REF', l2Moment: 'REF'),
  RadarProduct('Velocity', 'L2 VEL', l2Moment: 'VEL'),
  RadarProduct('Storm-Relative Velocity', 'L2 SRM', l2Moment: 'SRM'),
  RadarProduct('Rotation (Az. Shear)', 'L2 ROT', l2Moment: 'ROT'),
  RadarProduct('Spectrum Width', 'L2 SW', l2Moment: 'SW'),
  RadarProduct('Differential Reflectivity', 'L2 ZDR', l2Moment: 'ZDR'),
  RadarProduct('Correlation Coefficient', 'L2 CC', l2Moment: 'RHO'),
];

const productCref =
    RadarProduct('Composite Reflectivity', 'CREF', l2Moment: 'CREF',
        l2Volume: true);

/// On-device derived products, computed from the full Level 2 volume.
const derivedProducts = [
  productCref,
  RadarProduct('Vert. Integrated Liquid', 'VIL', l2Moment: 'VIL',
      l2Volume: true),
  RadarProduct('Echo Tops', 'ET', l2Moment: 'ET', l2Volume: true),
];

/// What a fresh pane opens on.
const defaultProduct = productRef;

/// The products that earn a permanent button on the toolbar, in the order a
/// warning operator actually walks them: what is there, how it is moving,
/// then the dual-pol fields that say what it is made of.
const quickProducts = [
  productRef,
  productVel,
  productZdr,
  productCc,
  productCref,
];

/// What the extra panes open on as the layout grows. Base reflectivity and
/// velocity first, then the dual-pol pair — one glance covering structure,
/// rotation and hail, which is what the multi-panel view exists for.
const panelPreset = [productRef, productVel, productZdr, productCc];

class Basemap {
  final String label;
  final String url;
  final String attribution;
  const Basemap(this.label, this.url, this.attribution);
}

const basemaps = [
  Basemap(
    'Dark',
    'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    '© OpenStreetMap © CARTO',
  ),
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

enum LightningSource {
  off('Off'),
  blitzortung('Blitzortung (ground network)'),
  glm('GOES GLM (satellite)'),
  both('Both');

  const LightningSource(this.label);
  final String label;

  bool get usesBlitzortung =>
      this == LightningSource.blitzortung || this == LightningSource.both;
  bool get usesGlm =>
      this == LightningSource.glm || this == LightningSource.both;
}

/// How the panes are arranged. Kept small on purpose: these four cover the
/// ways people actually compare radar products, and every extra option is
/// another thing to explain.
enum PaneLayout {
  single('Single', 1, 1),
  twoAcross('Two across', 2, 1),
  twoDown('Two down', 1, 2),
  quad('Four', 2, 2);

  const PaneLayout(this.label, this.cols, this.rows);
  final String label;
  final int cols;
  final int rows;

  int get count => cols * rows;
}
