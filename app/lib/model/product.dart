/// The radar products the app can display, and how each one is fetched.
library;

/// One product on offer in the UI.
///
/// Level 3 tilted products map to mnemonics like N0B/N1B/N2B/N3B (tilt digit
/// in the middle); Level 2 products carry a moment name and decode full
/// Archive II volumes on-device.
///
/// Instances are `const` and compared by identity, so always refer to the
/// shared constants below rather than constructing a copy — a freshly built
/// `Product` with the same fields is canonicalized to the same instance, but
/// only if every field matches exactly.
class Product {
  final String label;
  final String short;
  final String? tiltSuffix;
  final String? fixedCode;
  final String? l2Moment;

  /// Volume-integrated Level 2 products have no tilt dimension.
  final bool l2Volume;

  /// National MRMS mosaic: one grid for the whole country, no radar site.
  final bool isMrms;

  const Product(
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
}

const mrmsProduct = Product('National Mosaic', 'MRMS', isMrms: true);

/// The product the app opens on, and the one the mosaic auto-switch swaps
/// against. Defined on its own so it can be referred to by name instead of
/// as `l3Products[0]` — indexing a const list is not a const expression, so
/// the constant has to come first and the list reference it.
const defaultProduct = Product('Reflectivity', 'REF', tiltSuffix: 'B');

const l3Products = [
  defaultProduct,
  Product('Velocity', 'VEL', tiltSuffix: 'G'),
  Product('Differential Reflectivity', 'ZDR', tiltSuffix: 'X'),
  Product('Correlation Coefficient', 'CC', tiltSuffix: 'C'),
  Product('Specific Differential Phase', 'KDP', tiltSuffix: 'K'),
  Product('Hydrometeor Classification', 'HCA', tiltSuffix: 'H'),
  Product('Storm Total Precip', 'STP', fixedCode: 'DTA'),
];

const l2Products = [
  Product('Reflectivity', 'L2 REF', l2Moment: 'REF'),
  Product('Velocity', 'L2 VEL', l2Moment: 'VEL'),
  Product('Storm-Relative Velocity', 'L2 SRM', l2Moment: 'SRM'),
  Product('Rotation (Az. Shear)', 'L2 ROT', l2Moment: 'ROT'),
  Product('Spectrum Width', 'L2 SW', l2Moment: 'SW'),
  Product('Differential Reflectivity', 'L2 ZDR', l2Moment: 'ZDR'),
  Product('Correlation Coefficient', 'L2 CC', l2Moment: 'RHO'),
];

/// On-device derived products, computed from the full Level 2 volume.
const derivedProducts = [
  Product('Composite Reflectivity', 'CREF', l2Moment: 'CREF', l2Volume: true),
  Product('Vert. Integrated Liquid', 'VIL', l2Moment: 'VIL', l2Volume: true),
  Product('Echo Tops', 'ET', l2Moment: 'ET', l2Volume: true),
];
