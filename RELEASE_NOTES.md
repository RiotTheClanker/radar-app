<!-- version: v0.2.0 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

The biggest release so far, and the reason it is 0.2.0 rather than the next
0.1.x: the whole screen has been rebuilt, two new map layers arrive, and a
fault that made the 3D view unusable in the mountains is fixed.

### The workspace

The old screen floated rounded translucent cards over a single map, which
reads as a phone app: it spends space on padding and corner radius, and the
products you switch between constantly sit one popup menu deep. It is now
laid out the way a radar workstation is — thin solid strips docked to the
edges, square corners, small type, the common products on the bar as one
click.

**You can open up to four panes**: one, two across, two down, or a 2x2. Panes
share a site and pan together by default, since the reason to open four is
almost always one storm in four products — so the four-pane layout opens on
reflectivity, velocity, ZDR and correlation coefficient over the same radar.
Toolbar actions land on whichever pane has focus.

Sharing is not cosmetic. Four panes each polling for alerts and each holding
their own lightning connection would be four times the network for one
answer, and four animation clocks would drift apart, which defeats putting
two products side by side in the first place.

Two things that came out of it: renders are now sized to the pane rather than
the window, which in a 2x2 had been asking for four times the pixels needed;
and a cold start no longer fetches the fallback site's data and throws it
away when geolocation resolves — for a Level 2 product that was 10 MB per
pane.

Radar sites used to be reachable only by finding their dot on the map. There
is now a picker that matches on id, name or state.

### Two new layers

**Surface observations.** Temperature, dewpoint, wind and pressure from the
METAR network, drawn as station plots. One observation record carries all
four, so this is a measurement rather than an analysis. A station that has
stopped reporting is dimmed rather than left looking current.

**CAPE, from the HRRR model.** How much energy is available to a rising
parcel of air, in joules per kilogram — the field that separates air that
could produce a storm from air that cannot. This is the one thing here that
genuinely cannot come from observations: it needs a vertical profile at every
point, and the radiosonde network launches seventy balloons twice a day.

It is fetched as an 800 KB byte range out of the 130 MB hourly file rather
than the whole thing, using the index sidecar that names where each field
starts.

**It is labelled as a forecast everywhere it appears.** Everything else in
this app was seen by an instrument. This was computed, and drawn at the same
apparent confidence next to live warnings it would be read as an observation
by someone deciding whether to shelter. So the layer sits under a MODEL
heading rather than with the observations, the menu entry and the attribution
line both name the model run it came from, and a stale run says so.

### Fixed

**3D terrain floated above the storm, by the radar's own altitude.** Echo
heights are measured from the antenna; the terrain arrived as metres above
sea level and went in untouched. Same vertical axis, two different origins,
and the 4x vertical exaggeration multiplied the gap:

```
KICX  Cedar City  UT  3278 m  →  13.1 km of mountain on top of the volume
KBYX  Key West    FL    26 m  →   0.1 km, invisible
```

At Cedar City the terrain buried the storm; in Florida you would never have
noticed. Testing near Norman is why it went unseen for so long. The radar's
height now comes out of the volume file itself, so the ground sits at the
storm's feet and valleys below the radar are still drawn.

**Radar data never refreshed.** A pane left open showed the weather from the
moment it opened — new data was only ever fetched when you opened a pane or
changed something. There is now a refresh clock: a tick lists the newest scan
and compares it against what is on screen, so a quiet minute costs one
listing and no download.

**The dark basemap said "API KEY REQUIRED" across it.** CARTO began gating
anonymous requests behind a key, and answered with a real PNG that had the
notice drawn into it — so nothing downstream could tell it from a map.
Replaced with Esri's Dark Gray Canvas, which is keyless.

**Startup picked a radar that publishes nothing.** It chose the geometrically
closest site, which near Norman is a research radar with no public feed, and
then another one. The nearest sites are now probed rather than trusted, with
a timeout, falling back to the closest if none answer.

**Two panes fought over the cursor readout.** The aiming cursor keeps a
decoded sweep open in the engine, and that was one slot for the whole app —
so the second pane to switch its cursor on took the first pane's over. In a
reflectivity-vs-velocity layout that put a velocity number under a
reflectivity label, with nothing on screen saying so.

**Overlapping warnings.** Tapping where two alerts overlap opened one of them
and silently discarded the rest. It now offers the list of everything under
your finger, each one openable.

**Radar site dots were nearly impossible to hit.** A 10-pixel target drawn in
white at 24% opacity, on a dark basemap, under a translucent radar overlay,
outdoors at night. The invisible tap box around each dot is now
three times as wide while the dot itself stays small — two hundred
fingertip-sized circles would have buried the weather under them.

**The Android APK was built against an NDK nobody asked for**, which happened
to be present on the CI runner. One version now feeds both halves of the
build so they cannot drift apart again.

### Reading the sounding

Every number on the sounding plot was bare: pressures without hPa, isotherms
without degrees, wind without knots. Each axis now names its unit, the traces
are spelled out, and the indices panel says what each abbreviation stands for
and what it measures.

What it deliberately does not say is what a value means for this afternoon.
Explaining what CAPE measures is help; telling you a number means a tornado
is a forecast, from an app whose own README says not to rely on it.

Launch sites were a popup of seventy in table order. They are now ordered
outward from wherever you are looking, with the distance beside each name.

### Colour keys

Hydrometeor classification gets a list of its classes down the side of the
map, where the colour scale usually goes, since a scale labelled with class
ids is not something you can read a value off. The colours are the NWS's own,
which are not the ones our 3D classifier uses — a legend drawn with the wrong
palette would name every class incorrectly, so a test checks it against the
table the map is actually painted with.

The 3D view now has a key for **every** field, not just the classified one: a
scale in that field's own units for reflectivity, wind, ZDR and correlation
coefficient, and the class list for classification. It is built from the same
table the renderer painted with, so an imported `.pal` changes it too.

One thing it does not show for the continuous fields: the opacity slider
makes weak values transparent in 3D, and the key still lists them. It says
what a colour means, not what is currently visible.

### The key is the filter, for hydrometeor classification

The 3D filter used to be a switch: everything, or everything except clutter
and biological. Now every class in the key is its own switch — tap it to hide
that class, tap it again to bring it back. Hide everything but graupel and
hail and you are looking at the updrafts.

Per class rather than a slider because the classes have no natural order to
slide along. Any threshold would have to invent one, and would then only
reach the combinations that ordering happened to allow; "graupel and hail,
but not the snow below them" is not a prefix of anything.

A hidden class stays in the key, greyed and struck through, rather than
disappearing. You can see what you cut, you can tell it apart from a class
the radar never saw, and the row is still there to switch back on. "Show all"
at the top clears the lot.

### Much better classification, from checking it against the NWS

Comparing our answer to theirs at the four tilts they publish turned up three
real faults, none of which was visible by eye:

The melting level could land on the ground. It is found from the volume's own
correlation-coefficient dip, and overnight the boundary layer fills with
insects, whose correlation coefficient is worse than any melting snow. On a
3am volume that put the melting level at 200 m and called the whole volume
ice. The dip must now be above 1 km and be a genuine layer, cleaner above and
below.

Insects and ground clutter were tied to the freezing level, which has nothing
to do with either. They are now placed by height above ground.

Correlation coefficient carried the least weight of the three moments, when
it is the best single indicator of whether a return is weather at all.

Agreement went from 8% to **78.9%** averaged over ten radars from Florida to
Washington, ranging 66% to 95%; six of those sites were never used while
tuning and average 83.6%. Biological returns alone went from 35% to about
80%.

It still runs without the KDP and texture fields the operational algorithm
uses, and that shows: ground clutter it gets wrong more often than right, and
it is weakest over widespread stratiform ice. Good for reading storm
structure; not a substitute for the operational product.

### Faster

The engine's hot paths were measured rather than guessed at, and then worked
on where the time actually was:

- **Level 2 volumes decompress across threads.** Nine tenths of the time in
  opening a volume was bzip2, and it was running on one core.
- **Decoding is memoised.** Rendering a frame, reading a value off it and
  opening the cursor on it used to parse the same volume three times. The
  second and third are now free.
- **Rasterising is cheaper per pixel**, by hoisting the trigonometry that was
  being recomputed for every pixel in a row.

### For developers

The repo could always be built and run from the README, but nothing explained
why it is shaped the way it is. There is now `docs/architecture.md` and
friends: the layering rule, the two Rust crates and why they are separate,
what a new UI may assume, every data source with its cadence and attribution
terms, the engine's API by job, and what each thing costs. `CONTRIBUTING.md`
has the toolchain versions that matter and how to regenerate the four
generated things.

### Installing over 0.1.4

On Android you will have to uninstall 0.1.4 first. Release builds are still
signed with a debug key that CI regenerates on every run, and Android refuses
to install an APK over one signed by a different key. Signing with a stable
key is still the next thing on the list. Linux and Windows upgrade in place.

### Still not a warning system

Radar signatures are not confirmed tornadoes, model output is not an
observation, and none of this is official. Follow NWS warnings.
