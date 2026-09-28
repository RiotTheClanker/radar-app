#!/usr/bin/env python3
"""Write the built-in TDWR addon from the site table.

    python3 tools/gen_tdwr_addon.py

Reads app/lib/data/nexrad_sites.g.dart (itself generated from NCEI's list by
gen_sites.py) and writes app/assets/addons/tdwr.json. Run it after
regenerating the site table.

The addon only has to say where TDWR data lives and what its products are
called: each site's id is a built-in one, so its name, state and elevation
come from the table already.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITES = ROOT / "app/lib/data/nexrad_sites.g.dart"
OUT = ROOT / "app/assets/addons/tdwr.json"

# In NCEI's list but never seen in NOAA's Level 3 bucket: the two Puerto
# Rico airport radars. TSJU covers San Juan.
NO_DATA = {"TJBQ", "TJRV"}

# The toolbar asks for NEXRAD mnemonics; a TDWR names the same things
# differently, and has three tilts to NEXRAD's four and no dual-pol at all.
PRODUCTS = {
    "N0B": "TZ0", "N1B": "TZ1", "N2B": "TZ2",
    "N0G": "TV0", "N1G": "TV1", "N2G": "TV2",
}

ROW = re.compile(
    r"NexradSite\('(\w+)', '[^']*', '\w*', ([-\d.]+), ([-\d.]+), -?\d+, true\)"
)


def main():
    sites = []
    for m in ROW.finditer(SITES.read_text()):
        icao, lat, lon = m.group(1), float(m.group(2)), float(m.group(3))
        if icao in NO_DATA:
            continue
        sites.append({"id": icao, "lat": lat, "lon": lon, "products": PRODUCTS})
    if not sites:
        sys.exit(f"no TDWR rows found in {SITES}")

    addon = {
        "id": "builtin.tdwr",
        "name": "TDWR airport radars",
        "version": "1",
        "author": "Taa'a Yuku Radar",
        "description": (
            "The FAA's Terminal Doppler Weather Radars at 45 US airports. "
            "Short range (about 90 km) but a narrow beam, fine gates and a "
            "fast update — sharper than NEXRAD close to the metro areas they "
            "sit in. Reflectivity and velocity, three tilts; no dual-pol, no "
            "Level 2."
        ),
        "format": 1,
        "enabled": False,
        "sites": [
            {
                **s,
                "level3": {
                    "type": "s3",
                    "url": "https://unidata-nexrad-level3.s3.amazonaws.com",
                    "prefix": "{site3}_{product}_{yyyy}_{MM}_{dd}",
                },
            }
            for s in sites
        ],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(addon, indent=2) + "\n")
    print(f"wrote {OUT} with {len(sites)} sites")


if __name__ == "__main__":
    main()
