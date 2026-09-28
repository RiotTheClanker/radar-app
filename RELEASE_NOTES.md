<!-- version: v0.3.1 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### Built-in addons

Four addons now come with the app, all **off until you switch them on** in
**Tools → Addons**, under *Comes with the app*. They are ordinary addon
files, so they double as worked examples of the format.

- **TDWR airport radars.** The FAA's Terminal Doppler Weather Radars at 45 US
  airports, from NOAA's Level 3 feed. Short range (about 90 km), but a
  narrow beam, 150 m gates and a fast update — much sharper than NEXRAD
  close to the metro areas they sit in. Reflectivity and velocity on three
  tilts; the engine now decodes the TDWR products (TZ0–2, TV0–2, and the
  long-range TZL). They appear as diamonds and in the radar picker, and are
  never chosen as the startup radar.
- **Map reference layers.** US county and state lines, place names and roads
  drawn *over* the radar, and hillshade under it — each its own switch in
  Layers.
- **Hurricanes, wildfires and earthquakes.** NHC forecast cones, tracks and
  coastal watches for every active storm; perimeters of large US wildfires;
  earthquakes of magnitude 2.5+ in the past day.
- **Extra themes.** Night (red), High contrast, and OLED black.

The addon format gained what these needed, available to anyone's addon:
`wms` overlays; `simplify`, to thin heavy GeoJSON feeds as they load;
`bounds`, to keep a layer from being fetched where it has nothing;
`refreshMinutes` for tile layers; a site `products` map for radars that name
their products differently; and `"enabled": false` for an addon that should
wait to be switched on.

### Faster addon overlays

GeoJSON overlays are now parsed off the main thread, and the map reuses the
shapes it built instead of rebuilding them on every frame. A large live feed
no longer slows the whole app while its layer is on.
