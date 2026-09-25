#!/usr/bin/env python3
"""Write files in the open radar format (docs/open-format.md).

This is the reference writer: the few lines your own parser needs at the end
to turn whatever it decoded into something the app can draw. Standard
library only, so it runs anywhere Python does. numpy arrays work too — pass
`arr.tolist()`, or use `packed=True` for large sweeps.

    from radar_open import write_polar, write_grid

    write_polar("scan.json.gz",
                site=(35.33, -97.28), time=datetime.now(timezone.utc),
                product="reflectivity", elevation_deg=0.5,
                first_gate_m=2125, gate_size_m=250,
                azimuths=[i * 0.5 for i in range(720)],
                values=rows)          # one list of gate values per radial,
                                      # None for no data

Run it directly to write the sample files the example addon ships with:

    python3 radar_open.py docs/addons/examples/open-radar
"""

import base64
import gzip
import json
import math
import os
import struct
import sys
from datetime import datetime, timezone


def _time(t):
    if isinstance(t, (int, float)):
        return int(t)
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _pack_u8(flat, lo, hi):
    """Pack values into bytes: 0..254 across [lo, hi], 255 = no data."""
    step = (hi - lo) / 254.0 or 1.0
    raw = bytes(
        255 if v is None or (isinstance(v, float) and math.isnan(v))
        else max(0, min(254, round((v - lo) / step)))
        for v in flat
    )
    return {"type": "u8", "base64": base64.b64encode(raw).decode(),
            "scale": step, "offset": lo, "nodata": 255}


def _data(rows, packed, lo, hi):
    flat = [v for row in rows for v in row]
    if not packed:
        return {"values": flat}
    return {"packed": _pack_u8(flat, lo, hi)}


def _write(path, doc):
    text = json.dumps(doc, separators=(",", ":")).encode()
    if path.endswith(".gz"):
        text = gzip.compress(text)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(text)


def write_polar(path, *, site, time, product, first_gate_m, gate_size_m,
                azimuths, values, elevation_deg=0.5, unit=None, name=None,
                colors=None, packed=False, value_range=(-32.0, 95.0)):
    """One sweep. `values[i]` is the list of gate values for radial i."""
    doc = {
        "format": "radar-open", "version": 1, "kind": "polar",
        "site": {"lat": site[0], "lon": site[1]},
        "time": _time(time), "product": product,
        "elevationDeg": elevation_deg,
        "firstGateM": first_gate_m, "gateSizeM": gate_size_m,
        "gates": len(values[0]), "azimuths": list(azimuths),
    }
    if unit is not None:
        doc["unit"] = unit
    if name is not None:
        doc["name"] = name
    if colors is not None:
        doc["colors"] = colors
    doc.update(_data(values, packed, *value_range))
    _write(path, doc)


def write_grid(path, *, north, south, east, west, time, product, values,
               unit=None, name=None, colors=None, packed=False,
               value_range=(0.0, 100.0)):
    """A lat/lon grid. `values[row]` runs west to east, row 0 is north."""
    doc = {
        "format": "radar-open", "version": 1, "kind": "grid",
        "north": north, "south": south, "east": east, "west": west,
        "nx": len(values[0]), "ny": len(values),
        "time": _time(time), "product": product,
    }
    if unit is not None:
        doc["unit"] = unit
    if name is not None:
        doc["name"] = name
    if colors is not None:
        doc["colors"] = colors
    doc.update(_data(values, packed, *value_range))
    _write(path, doc)


def _samples(folder):
    """A synthetic storm near Oklahoma City, and a rainfall grid."""
    now = datetime.now(timezone.utc).replace(microsecond=0)
    stamp = now.strftime("%Y%m%d_%H%M%S")
    site = (35.45, -97.35)
    gates, gate_m = 240, 500.0

    def cell(az, r_km, c_az, c_r, peak, width):
        d_az = min(abs(az - c_az), 360 - abs(az - c_az)) * math.pi / 180 * r_km
        d = math.hypot(d_az, r_km - c_r)
        return peak * math.exp(-(d / width) ** 2)

    ref, vel = [], []
    azimuths = [i * 1.0 for i in range(360)]
    for az in azimuths:
        rrow, vrow = [], []
        for g in range(gates):
            r = (g + 0.5) * gate_m / 1000
            z = max(cell(az, r, 250, 45, 62, 9), cell(az, r, 300, 80, 48, 14),
                    cell(az, r, 60, 30, 35, 20))
            rrow.append(round(z, 1) if z > 8 else None)
            # A couplet on the big cell: inbound one side of 250°, outbound
            # the other, over a light background flow.
            d_az = (az - 250 + 180) % 360 - 180
            v = (28 * math.tanh(d_az / 3) * math.exp(-(d_az / 10) ** 2)
                 * math.exp(-((r - 45) / 6) ** 2)
                 + 8 * math.cos((az - 225) * math.pi / 180)) if z > 8 else None
            vrow.append(round(v, 1) if v is not None else None)
        ref.append(rrow)
        vel.append(vrow)

    write_polar(f"{folder}/data/REF/sample_{stamp}.json.gz", site=site,
                time=now, product="reflectivity", first_gate_m=gate_m / 2,
                gate_size_m=gate_m, azimuths=azimuths, values=ref,
                packed=True, value_range=(-32.0, 95.0))
    write_polar(f"{folder}/data/VEL/sample_{stamp}.json.gz", site=site,
                time=now, product="velocity", unit="m/s", first_gate_m=gate_m / 2,
                gate_size_m=gate_m, azimuths=azimuths, values=vel,
                packed=True, value_range=(-64.0, 64.0))

    ny, nx = 60, 80
    rain = [[max(0.0, 3.0 * math.exp(-(((x - 30) / 12) ** 2 + ((y - 25) / 9) ** 2)))
             for x in range(nx)] for y in range(ny)]
    rain = [[round(v, 2) if v > 0.05 else None for v in row] for row in rain]
    write_grid(f"{folder}/data/STP/sample_{stamp}.json.gz",
               north=35.95, south=34.95, east=-96.85, west=-97.95, time=now,
               product="rain gauge analysis", unit="in", values=rain,
               colors={"stops": [[0.05, "#9EE6FF"], [0.5, "#2E7DFF"],
                                 [1.5, "#1BC41B"], [2.5, "#FFD000"],
                                 [3.0, "#FF3B30"]]})


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    _samples(out)
    print(f"wrote sample REF, VEL and STP files under {out}/data/")
