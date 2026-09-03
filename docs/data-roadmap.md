# Roadmap: more data layers

> Tracked as issues #51 (station obs) → #52 (analysed fields) → #53 (GRIB2
> spike) → #54 (CAPE and shear). The arrows are real dependencies, not a
> preference.

A plan for the overlays this app does not have yet — temperature, humidity,
pressure, and a field of available energy in J/kg — plus what has to be true
before each becomes possible.

Written as a plan rather than a wish list because two of the obvious
shortcuts turn out not to exist, and knowing that up front changes the
order the work should be done in.

## The two findings that shape everything below

Both were checked against the code, not assumed.

**1. The GRIB2 reader will not read model data.**
`rust/radar_core/src/mrms.rs` supports exactly one grid template and one
packing template:

| | Supported | Needed for HRRR / RTMA |
|---|---|---|
| Grid definition | `3.0` — regular lat/lon | Lambert Conformal (`3.30`) |
| Data packing | `5.41` — PNG compression | complex packing, or JPEG2000 (`5.40`) |

It says so itself, and fails loudly rather than silently: *"only lat/lon grid
template 3.0 supported"*, *"only PNG packing (template 5.41) supported"*.
So "we already parse GRIB2" is true of MRMS and of nothing else. Adding a
model source means a conformal-conic projection **and** a new unpacking
path — and if the fields we want are JPEG2000, that is effectively the
`libopenjp2` dependency this project has avoided on Android from the start.

**2. The HDF5 reader will not read arbitrary netCDF4 either.**
`rust/radar_core/src/glm.rs` is deliberately narrow — version-2 object
headers, contiguous or *single*-chunk layouts, deflate + shuffle, and
attribute-driven dataset discovery that is "robust for this fixed producer".
It reads GOES GLM. It is not a general netCDF4 reader, so serving model
fields as netCDF instead of GRIB2 does not route around finding 1.

**What follows from that:** every gridded model field costs real decoder
work, and none of it is shared with what already exists. Station
observations cost almost none. That is the whole reason for the ordering
below.

## The decision to make first

Every source in this app today is an **observation**: a radar scanned it, a
sonde flew through it, a sensor detected it. Temperature, humidity and
pressure *fields* are not observations — they are analyses or model output.

That is not a reason to refuse them, but it changes what the app is, and it
changes what it owes the reader. A model forecast drawn with the same
confidence as a radar return misleads, and this app's own README says never
to rely on it as your only source of warnings. So:

> **Any model-derived layer must be labelled as model output, with its run
> time visible.** An observation and a forecast must not look alike.

Worth settling before the first one ships, because it is much harder to
retrofit into a legend than to design in.

## Tier 1 — station observations

**What:** surface observations plotted as station points — temperature,
dewpoint, wind, pressure, all from the same record.

**Why first:** it answers three of the four requests (temperature,
humidity, pressure) using real observations, needs no new decoder, and fits
what the app already is. It is also the most useful of the lot for
nowcasting: a dewpoint gradient across a station plot shows you the boundary
that storms will fire on, which a smoothed field tends to blur away.

**Work:** a JSON fetcher in `lib/data/`, a station-plot marker layer, and a
station table. No engine work at all.

**Open question — the source.** This needs settling first and is not
something to guess at:

- `api.weather.gov` is already a source here, with the User-Agent plumbing
  done, but it has no bulk "all current observations" endpoint — its
  observation routes are per station, and several thousand requests is not a
  fetch strategy.
- Aviation Weather Center and the Iowa State Mesonet both publish bulk
  current-observation feeds, free and keyless, and at least one of them
  supports a bounding box, which is the shape this needs.

**First step:** confirm one endpoint that returns every observation in a
bounding box in a single request, and what it costs to poll. Everything else
in this tier is straightforward once that exists.

## Tier 2 — fields from those observations

**What:** the station values interpolated into smooth temperature, dewpoint
and mean-sea-level-pressure fields, plus pressure centres and isobars.

**Why it is the interesting one:** this is a genuinely custom analysis
computed on the device from observations — not a picture of someone else's
model. It is also the honest version of "the classic high and low pressure
map": find the local extrema in the analysed MSLP field, mark them H and L,
and contour the isobars around them.

**Work:**
- Barnes or Cressman objective analysis in `rust/radar_core/src/process/` —
  well-trodden maths, and the right layer for it.
- Marching squares for isobars, which the renderer does not do yet.
- Local-extrema detection for the H/L glyphs.

**Depends on:** Tier 1.

**Worth knowing:** an analysis is only as good as its station density, and
it will be visibly worse over the mountain west and offshore. Say so in the
legend rather than letting a smooth field imply confidence it has not
earned.

## Tier 3 — energy in the air (J/kg), and shear

**What:** a field of convective available potential energy, and the wind
shear that goes with it.

**The constraint that decides the approach:** CAPE needs a *vertical
profile* at every grid point. This app has about 70 radiosondes over CONUS,
launched twice a day. Interpolating those gives a coarse, twelve-hourly
field — defensible, and close to useless for nowcasting a storm this
afternoon.

So there are two real options, and both run through finding 1:

**(a) Display a model's CAPE field.** Hourly, 3 km, already computed. Fast
to ship once the decoder exists, but it is their parcel choice, not ours.

**(b) Fetch model temperature and dewpoint on pressure levels and run our
own parcel ascent.** This reuses `lib/data/sounding_indices.dart`, which
already computes CAPE, CIN, LI, LCL/LFC/EL from a profile — so the physics
is written. It also means we control the parcel (surface-based, mixed-layer,
most-unstable), which genuinely changes the answer and is the real argument
for doing it ourselves. Costs far more data per refresh.

**Recommended:** (a) first to get the layer on screen and prove the decoder,
(b) afterwards as the version worth having. Do not start either before the
spike below.

**Shear and storm-relative helicity belong here too.** CAPE alone does not
forecast severe weather; the app already computes both from a sounding, and
the same profile data would give both as fields.

## The gate: a GRIB2 capability spike

Tier 3 is blocked on one cheap question, and it should be answered before
any of it is scheduled.

**Fetch one HRRR (or RTMA) file carrying a field we want, and read its
section 5, bytes 10–11 — the data representation template number.**

- `5.0` simple packing, `5.2`/`5.3` complex packing (with spatial
  differencing) — hard but self-contained, pure Rust, no new dependency.
- `5.40` JPEG2000 — needs a JPEG2000 decoder, which is the dependency this
  project exists to avoid on mobile. If this is the answer, Tier 3 needs a
  different data route entirely, and that is worth knowing before anyone
  writes a line of it.

Also read section 3 to confirm the grid template, since Lambert Conformal
support is needed either way.

**Deliverable:** a note in the issue saying which templates the fields we
want actually use, and therefore which of (a)/(b) is reachable. An hour of
work that decides weeks of it.

## Also worth having, once the above lands

Roughly by value for storm prediction:

- **700–500 mb lapse rates** — mid-level instability, from the same profile
  data as Tier 3.
- **GOES ABI satellite imagery** — cloud tops and overshooting tops. The
  GOES buckets and the polling pattern already exist for GLM, though the
  files are much larger and the narrow HDF5 reader may not stretch to them.
- **WPC surface analysis fronts** — what makes a pressure map readable.
- **Composite indices (STP, SCP)** — cheap once CAPE and shear are in, and
  the parcel code is already here.

## Not on this roadmap

**Mobile radar** — closed as not planned in #38. Three blockers, the deepest
being that this app assumes a radar does not move: storm tracks are
positioned by azimuth and range from a fixed site, and the 3D grid takes the
site as its origin. #38 records what would reopen it.

**A general GRIB2 or netCDF4 library.** Both readers here are narrow on
purpose, so there is no libhdf5, libgrib or eccodes to cross-compile for
Android. Widening them is a decision to make deliberately and per template,
not a refactor to drift into.
