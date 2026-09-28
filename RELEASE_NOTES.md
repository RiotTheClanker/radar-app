<!-- version: v0.3.1 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### TDWR airport radars

The engine now decodes the FAA's Terminal Doppler Weather Radar products —
base reflectivity (TZ0–2), velocity (TV0–2) and long-range reflectivity
(TZL). TDWRs sit at 45 US airports: short range (about 90 km), but a narrow
beam, 150 m gates and a fast update, so they are much sharper than NEXRAD
close to the metro areas they cover. Install the **TDWR addon** (below) to
add them to the map and the radar picker; they are never chosen as the
startup radar.

### Ready-made addons

Four addons are now published for installing from a link in **Tools →
Addons**: TDWR airport radars; map reference layers (US county and state
lines, place names and roads over the radar, hillshade under it);
hurricanes, wildfires and earthquakes (NHC cones and tracks, large US fire
perimeters, M2.5+ quakes); and extra themes (Night red, High contrast, OLED
black). Paste one of these links into **Tools → Addons** and press Install:

- TDWR airport radars — `https://raw.githubusercontent.com/RiotTheClanker/radar-app/main/docs/addons/catalog/tdwr.json`
- Map reference layers — `https://raw.githubusercontent.com/RiotTheClanker/radar-app/main/docs/addons/catalog/map-layers.json`
- Hurricanes, wildfires and earthquakes — `https://raw.githubusercontent.com/RiotTheClanker/radar-app/main/docs/addons/catalog/hazards.json`
- Extra themes — `https://raw.githubusercontent.com/RiotTheClanker/radar-app/main/docs/addons/catalog/themes.json`

### Addon format

New, and available to anyone's addon: `wms` overlays; `simplify`, to thin
heavy GeoJSON feeds as they load; `bounds`, to keep a layer from being
fetched where it has nothing; `refreshMinutes` for tile and WMS layers; a
site `products` map for radars that name their products differently; and
`"enabled": false` for an addon that should wait to be switched on.

### Faster addon overlays

GeoJSON overlays are now parsed off the main thread, and the map reuses the
shapes it built instead of rebuilding them on every frame. A large live feed
no longer slows the whole app while its layer is on.
