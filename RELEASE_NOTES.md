<!-- version: v0.3.0 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### Addons

The app now takes **addons**: JSON files that add what it does not ship for
everyone. A county's roads and shelters, a university radar nobody put on
AWS, a chase team's own tile server, a red theme for night driving. An addon
is data, never code — nothing in one runs.

One addon can add any mix of:

- **Radar sites, with their own data.** A site's files can come from any
  S3-compatible bucket (the same protocol NOAA's use, and what MinIO, R2 and
  Wasabi answer to), from any web folder that lists its files — nginx with
  `autoindex on` is enough — or from **a folder on your own device**, such as
  a receiver's output directory. Headers can be set for a source that needs
  a key. An addon can also re-point an existing site, such as KTLX, at a
  mirror.
- **Your own parser, for any radar format.** NEXRAD files are decoded by the
  app. For anything else there is now an **open radar format**: a small,
  documented JSON description of a sweep (site, radials, gates, values) or
  of a lat/lon grid. Your converter, in any language, writes it; the app
  draws it with its own palettes (including imported `.pal` files), colour
  key, aiming cursor, loops and replay. A file can bring its own colour
  scale for data no radar palette fits. A standard-library Python writer is
  in `tools/open_format/radar_open.py`, and an example addon reads
  synthetic sample files from a local folder with no network at all.
- **Map overlays.** GeoJSON — from a file, a URL (optionally refreshed every
  few minutes, for live positions), or written inline — and tile layers.
  Each chooses whether it sits under the radar, like imagery, or over it,
  like roads and boundaries. Per-feature colours follow the simplestyle
  convention that geojson.io and most exporters already write.
- **Places.** Shelters, spotter posts, schools, home — from a list in the
  file or a CSV. Tap one for its range and bearing from the radar and **how
  high the beam is over it**, which is the answer to "why doesn't the radar
  show the rotation I can see from here".
- **Themes** for the chrome — bars, menus, text — never the radar, whose
  colours are data. An example all-red night-vision theme is included.
- **Colour tables**: `.pal` files that join the Tools menu's list.

Install from a link in **Tools → Addons**, or drop files in
`~/.config/taa-yuku-radar/addons/`. Each addon has an on/off switch, and
anything the loader skipped is listed under it with the reason — a mistake
in one item costs that item, not the whole addon. Overlays and place groups
are switched on and off in **Layers → ADDONS**, themes in **Tools → THEME**.
Your choices are remembered between runs.

An addon's radar is drawn as a diamond rather than a dot and carries its
addon's name in the radar picker, and its owner's credit is on the map while
you are on it, the same as the basemap's. The format is documented in
[docs/addons.md](https://github.com/RiotTheClanker/radar-app/blob/main/docs/addons.md), with examples in
[docs/addons/examples](https://github.com/RiotTheClanker/radar-app/tree/main/docs/addons/examples).

### Fixes

- **A radar that failed to load no longer shows the previous radar's
  picture.** Switching to a site whose data could not be fetched left the
  old site's frames on screen under the new site's name. The pane is now
  cleared, and says why.
- **With one pane, a load error is now visible.** The error only ever
  appeared in the pane header, which is not drawn in the single-pane layout,
  so a radar that failed to load looked like a radar with nothing to show.
  The status bar now carries a LOAD FAILED chip; tap or hover it for the
  reason.
