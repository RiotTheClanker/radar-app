# Example addons

Copy any of these into your addons folder (Tools → Addons… shows where), or
install one from its raw GitHub link. The format is in
[../../addons.md](../../addons.md).

| Example | Shows |
|---|---|
| [test-addon.json](test-addon.json) | One of everything in a single file, to check addons work: a radar reading KTLX's live data through the custom-source path (drawn as a diamond east of OKC), an inline GeoJSON overlay, places and a theme |
| [night-red.json](night-red.json) | A theme on its own |
| [spotter-pack/](spotter-pack/) | A folder addon: places from inline items and a CSV, a GeoJSON area, an optional tile layer |
| [open-radar/](open-radar/) | A radar read from **local files** in the [open format](../../open-format.md): synthetic REF, VEL and a rainfall grid, no network needed. Regenerate the data with `python3 tools/open_format/radar_open.py docs/addons/examples/open-radar` |
| [custom-radar.json](custom-radar.json) | A radar site with its own Level 2 (S3) and Level 3 (web index) sources — a template, the URLs are placeholders |

A test loads every file here, so an example that stops parsing fails CI.
