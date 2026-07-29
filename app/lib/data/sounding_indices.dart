/// Thermodynamic and kinematic indices computed from a sounding.
///
/// All of it on the device, from the levels themselves — nothing here is
/// fetched. The formulas are the standard ones: Bolton (1980) for the LCL and
/// for equivalent potential temperature, a moist adiabat integrated upward
/// for the parcel trace, and Bunkers (2000) for the storm motion that
/// storm-relative helicity is measured against.
library;

import 'dart:math' as math;

import 'sounding_fetcher.dart';

/// Everything derived from one sounding.
class SoundingIndices {
  /// Convective available potential energy and inhibition, J/kg, for a parcel
  /// lifted from the surface.
  final double? capeJkg;
  final double? cinJkg;

  /// Most-unstable parcel in the lowest 300 hPa — the one that actually goes
  /// up when the surface is capped.
  final double? muCapeJkg;

  /// Lifting condensation, free convection and equilibrium levels, m AGL.
  final double? lclM;
  final double? lfcM;
  final double? elM;

  /// Lifted index, °C. Negative is unstable.
  final double? liC;

  /// Precipitable water, mm.
  final double? pwatMm;

  /// Height of the freezing level, m AGL — where hail starts melting.
  final double? freezingM;

  /// Bulk wind difference over the layer, knots.
  final double? shear1kmKt;
  final double? shear6kmKt;

  /// Storm-relative helicity, m²/s², against the Bunkers right mover.
  final double? srh1km;
  final double? srh3km;

  /// Estimated right-moving supercell motion, degrees and knots.
  final double? stormDirDeg;
  final double? stormKt;

  const SoundingIndices({
    this.capeJkg,
    this.cinJkg,
    this.muCapeJkg,
    this.lclM,
    this.lfcM,
    this.elM,
    this.liC,
    this.pwatMm,
    this.freezingM,
    this.shear1kmKt,
    this.shear6kmKt,
    this.srh1km,
    this.srh3km,
    this.stormDirDeg,
    this.stormKt,
  });
}

// ------------------------------------------------------------- constants --

const _rd = 287.04; // dry air gas constant, J/(kg K)
const _cp = 1005.7; // specific heat at constant pressure, J/(kg K)
const _lv = 2.501e6; // latent heat of vaporisation, J/kg
const _eps = 0.622; // ratio of gas constants, water to dry air
const _g = 9.80665;

/// Saturation vapour pressure over water, hPa. Bolton (1980) eq. 10.
double saturationVapourPressure(double tempC) =>
    6.112 * math.exp(17.67 * tempC / (tempC + 243.5));

/// Mixing ratio, kg/kg, from dewpoint and pressure.
double mixingRatio(double dewpointC, double pressureHpa) {
  final e = saturationVapourPressure(dewpointC);
  final denom = pressureHpa - e;
  if (denom <= 0) return 0;
  return _eps * e / denom;
}

/// Temperature a parcel reaches lifting dry adiabatically, °C.
double dryLift(double tempC, double fromHpa, double toHpa) =>
    (tempC + 273.15) * math.pow(toHpa / fromHpa, _rd / _cp) - 273.15;

/// Lifting condensation level temperature, K. Bolton (1980) eq. 15.
double lclTempK(double tempC, double dewpointC) {
  final tk = tempC + 273.15;
  final tdk = dewpointC + 273.15;
  return 1.0 / (1.0 / (tdk - 56.0) + math.log(tk / tdk) / 800.0) + 56.0;
}

/// Moist adiabatic lapse rate, K per hPa, at a saturated parcel's state.
double _moistLapsePerHpa(double tempK, double pressureHpa) {
  final tc = tempK - 273.15;
  final es = saturationVapourPressure(tc);
  final ws = _eps * es / math.max(pressureHpa - es, 1e-6);
  final num = 1.0 + _lv * ws / (_rd * tempK);
  final den = 1.0 + _lv * _lv * ws * _eps / (_cp * _rd * tempK * tempK);
  // dT/dp along a moist adiabat, from the hydrostatic + first law relation.
  return (_rd * tempK / (_cp * pressureHpa)) * (num / den);
}

/// Lift a saturated parcel from one pressure to another along a moist
/// adiabat, integrating in small steps because the lapse rate changes as it
/// goes.
double moistLift(double tempC, double fromHpa, double toHpa) {
  var t = tempC + 273.15;
  var p = fromHpa;
  final steps = math.max(1, ((fromHpa - toHpa).abs() / 5.0).ceil());
  final dp = (toHpa - fromHpa) / steps;
  for (var i = 0; i < steps; i++) {
    t += _moistLapsePerHpa(t, p) * dp;
    p += dp;
  }
  return t - 273.15;
}

/// Virtual temperature, °C — the buoyancy a parcel actually feels, since
/// moist air is lighter than dry air at the same temperature.
double virtualTempC(double tempC, double dewpointC, double pressureHpa) {
  final w = mixingRatio(dewpointC, pressureHpa);
  return (tempC + 273.15) * (1 + w / _eps) / (1 + w) - 273.15;
}

// ----------------------------------------------------------------- parcel --

/// Height at a given pressure, interpolated between the levels that bracket
/// it. Heights vary linearly with log pressure, near enough over one layer.
double? _heightAtPressure(List<SoundingLevel> levels, double p) {
  for (var i = 1; i < levels.length; i++) {
    final a = levels[i - 1], b = levels[i];
    if (a.heightM == null || b.heightM == null) continue;
    if (p <= a.pressureHpa && p >= b.pressureHpa) {
      final span = math.log(a.pressureHpa) - math.log(b.pressureHpa);
      if (span.abs() < 1e-9) return a.heightM;
      final f = (math.log(a.pressureHpa) - math.log(p)) / span;
      return a.heightM! + (b.heightM! - a.heightM!) * f;
    }
  }
  return null;
}

class _ParcelResult {
  final double cape;
  final double cin;
  final double? lcl;
  final double? lfc;
  final double? el;
  final double? li;
  const _ParcelResult(this.cape, this.cin, this.lcl, this.lfc, this.el, this.li);
}

/// Lift a parcel from [start] and integrate its buoyancy.
_ParcelResult _liftParcel(List<SoundingLevel> levels, SoundingLevel start) {
  final t0 = start.tempC, d0 = start.dewpointC, p0 = start.pressureHpa;
  if (t0 == null || d0 == null) {
    return const _ParcelResult(0, 0, null, null, null, null);
  }
  final surfaceM = levels.first.heightM ?? 0;

  // Where it saturates. The height is interpolated to that pressure rather
  // than snapped to the next reported level — mandatory levels are hundreds
  // of metres apart, which would put a 900 m cloud base at 1400 m.
  final tLclK = lclTempK(t0, d0);
  final pLcl = p0 * math.pow((tLclK) / (t0 + 273.15), _cp / _rd);
  final lclHeight = _heightAtPressure(levels, pLcl.toDouble());

  var cape = 0.0, cin = 0.0;
  double? lfc, el, li;
  double? prevBuoy, prevHeight;
  var everPositive = false;

  for (final l in levels) {
    if (l.pressureHpa > p0) continue; // below the parcel's origin
    final envT = l.tempC;
    final h = l.heightM;
    if (envT == null || h == null) continue;

    // Parcel temperature at this level: dry to the LCL, moist above it.
    final double parcelT;
    if (l.pressureHpa >= pLcl) {
      parcelT = dryLift(t0, p0, l.pressureHpa);
    } else {
      final tAtLcl = tLclK - 273.15;
      parcelT = moistLift(tAtLcl, pLcl, l.pressureHpa);
    }

    // Compare virtual temperatures. Above the LCL the parcel is saturated,
    // so its dewpoint equals its temperature.
    final envTv = l.dewpointC == null
        ? envT
        : virtualTempC(envT, l.dewpointC!, l.pressureHpa);
    final parcelTv = l.pressureHpa >= pLcl
        ? virtualTempC(parcelT, dryLift(d0, p0, l.pressureHpa), l.pressureHpa)
        : virtualTempC(parcelT, parcelT, l.pressureHpa);

    final buoy = _g * (parcelTv - envTv) / (envTv + 273.15);

    if ((l.pressureHpa - 500).abs() < 1) li = envT - parcelT;

    if (prevBuoy != null && prevHeight != null) {
      final dz = h - prevHeight;
      if (dz > 0) {
        final area = 0.5 * (buoy + prevBuoy) * dz;
        if (buoy > 0 && prevBuoy > 0) {
          cape += area;
          everPositive = true;
          lfc ??= prevHeight;
        } else if (buoy <= 0 && prevBuoy <= 0) {
          // Only inhibition below the level of free convection counts.
          if (!everPositive) cin += area;
        } else {
          // Crossing: split at the zero, roughly.
          final f = prevBuoy.abs() / (prevBuoy.abs() + buoy.abs());
          final cross = prevHeight + dz * f;
          if (buoy > 0) {
            lfc ??= cross;
            cape += 0.5 * buoy * (h - cross);
            if (!everPositive) cin += 0.5 * prevBuoy * (cross - prevHeight);
            everPositive = true;
          } else {
            cape += 0.5 * prevBuoy * (cross - prevHeight);
            el ??= cross;
          }
        }
      }
    }
    prevBuoy = buoy;
    prevHeight = h;
  }

  return _ParcelResult(
    math.max(cape, 0),
    math.min(cin, 0),
    lclHeight == null ? null : lclHeight - surfaceM,
    lfc == null ? null : lfc - surfaceM,
    el == null ? null : el - surfaceM,
    li,
  );
}

// -------------------------------------------------------------- kinematic --

/// Wind as u/v components in knots. Meteorological direction is where the
/// wind comes FROM, so both components are negated.
(double, double) _uv(double dirDeg, double speedKt) {
  final r = dirDeg * math.pi / 180.0;
  return (-speedKt * math.sin(r), -speedKt * math.cos(r));
}

/// Wind interpolated to a height above ground, or null if out of range.
(double, double)? _windAt(List<SoundingLevel> levels, double targetM) {
  SoundingLevel? below, above;
  for (final l in levels) {
    if (!l.hasWind || l.heightM == null) continue;
    if (l.heightM! <= targetM) below = l;
    if (l.heightM! >= targetM) {
      above = l;
      break;
    }
  }
  if (below == null && above == null) return null;
  if (below == null) return _uv(above!.windDirDeg!, above.windKt!);
  if (above == null || above.heightM == below.heightM) {
    return _uv(below.windDirDeg!, below.windKt!);
  }
  final f = (targetM - below.heightM!) / (above.heightM! - below.heightM!);
  final (u0, v0) = _uv(below.windDirDeg!, below.windKt!);
  final (u1, v1) = _uv(above.windDirDeg!, above.windKt!);
  return (u0 + (u1 - u0) * f, v0 + (v1 - v0) * f);
}

/// Storm-relative helicity over a layer, m²/s², against a storm motion.
double? _srh(
  List<SoundingLevel> levels,
  double surfaceM,
  double topAgl,
  double stormU,
  double stormV,
) {
  final pts = <(double, double, double)>[];
  for (final l in levels) {
    if (!l.hasWind || l.heightM == null) continue;
    final agl = l.heightM! - surfaceM;
    if (agl < 0 || agl > topAgl) continue;
    final (u, v) = _uv(l.windDirDeg!, l.windKt!);
    // Knots to m/s, since helicity is quoted in SI.
    pts.add((agl, u * 0.514444, v * 0.514444));
  }
  if (pts.length < 2) return null;
  final su = stormU * 0.514444, sv = stormV * 0.514444;
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final (_, u0, v0) = pts[i - 1];
    final (_, u1, v1) = pts[i];
    total += ((u1 - su) * (v0 - sv)) - ((u0 - su) * (v1 - sv));
  }
  return total;
}

/// Compute every index this app shows.
SoundingIndices computeIndices(Sounding sounding) {
  final levels = sounding.levels
      .where((l) => l.heightM != null)
      .toList(growable: false);
  if (levels.length < 3) return const SoundingIndices();
  final surfaceM = levels.first.heightM!;

  final sb = _liftParcel(levels, levels.first);

  // Most-unstable: try each level in the lowest 300 hPa and keep the best.
  var muCape = sb.cape;
  final pSfc = levels.first.pressureHpa;
  for (final l in levels) {
    if (l.pressureHpa < pSfc - 300) break;
    if (l.tempC == null || l.dewpointC == null) continue;
    final r = _liftParcel(levels, l);
    if (r.cape > muCape) muCape = r.cape;
  }

  // Precipitable water: integrate mixing ratio through the column.
  double? pwat;
  {
    var total = 0.0;
    SoundingLevel? prev;
    for (final l in levels) {
      if (l.dewpointC == null) continue;
      if (prev != null) {
        final w0 = mixingRatio(prev.dewpointC!, prev.pressureHpa);
        final w1 = mixingRatio(l.dewpointC!, l.pressureHpa);
        final dp = (prev.pressureHpa - l.pressureHpa) * 100; // Pa
        if (dp > 0) total += 0.5 * (w0 + w1) * dp / _g;
      }
      prev = l;
    }
    if (total > 0) pwat = total; // kg/m^2 is mm of water
  }

  // Freezing level, interpolated.
  double? freezing;
  for (var i = 1; i < levels.length; i++) {
    final a = levels[i - 1], b = levels[i];
    if (a.tempC == null || b.tempC == null) continue;
    if (a.tempC! >= 0 && b.tempC! < 0) {
      final f = a.tempC! / (a.tempC! - b.tempC!);
      freezing = a.heightM! + (b.heightM! - a.heightM!) * f - surfaceM;
      break;
    }
  }

  // Shear and storm motion.
  final sfcWind = _windAt(levels, surfaceM);
  final w1 = _windAt(levels, surfaceM + 1000);
  final w6 = _windAt(levels, surfaceM + 6000);
  double? shear1, shear6;
  if (sfcWind != null && w1 != null) {
    shear1 = math.sqrt(math.pow(w1.$1 - sfcWind.$1, 2) +
        math.pow(w1.$2 - sfcWind.$2, 2));
  }
  if (sfcWind != null && w6 != null) {
    shear6 = math.sqrt(math.pow(w6.$1 - sfcWind.$1, 2) +
        math.pow(w6.$2 - sfcWind.$2, 2));
  }

  double? stormDir, stormKt, srh1, srh3;
  if (sfcWind != null && w6 != null) {
    // Bunkers right mover: the 0-6 km mean wind, pushed 7.5 m/s to the right
    // of the shear vector.
    final meanU = (sfcWind.$1 + w6.$1) / 2;
    final meanV = (sfcWind.$2 + w6.$2) / 2;
    final shU = w6.$1 - sfcWind.$1;
    final shV = w6.$2 - sfcWind.$2;
    final mag = math.sqrt(shU * shU + shV * shV);
    if (mag > 0.1) {
      const dKt = 7.5 / 0.514444; // 7.5 m/s in knots
      final ru = meanU + dKt * (shV / mag);
      final rv = meanV - dKt * (shU / mag);
      stormKt = math.sqrt(ru * ru + rv * rv);
      stormDir = (math.atan2(-ru, -rv) * 180 / math.pi + 360) % 360;
      srh1 = _srh(levels, surfaceM, 1000, ru, rv);
      srh3 = _srh(levels, surfaceM, 3000, ru, rv);
    }
  }

  return SoundingIndices(
    capeJkg: sb.cape,
    cinJkg: sb.cin,
    muCapeJkg: muCape,
    lclM: sb.lcl,
    lfcM: sb.lfc,
    elM: sb.el,
    liC: sb.li,
    pwatMm: pwat,
    freezingM: freezing,
    shear1kmKt: shear1,
    shear6kmKt: shear6,
    srh1km: srh1,
    srh3km: srh3,
    stormDirDeg: stormDir,
    stormKt: stormKt,
  );
}
