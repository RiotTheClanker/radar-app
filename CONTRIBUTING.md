# Contributing

Everything you need to get from a fresh clone to a running app, and the
conventions the repo expects once you are there.

New here? Read [docs/architecture.md](docs/architecture.md) first — it is
short, and it explains why the tree is shaped the way it is.

## Toolchains

| Tool | Version | Why that version |
|---|---|---|
| Flutter | **3.44.8** | What CI pins (`FLUTTER_VERSION` in `.github/workflows/build.yml`). 3.44+ works; matching CI avoids surprises |
| Dart SDK | ^3.12.2 | Comes with Flutter; pinned in `app/pubspec.yaml` |
| Rust | stable | `dtolnay/rust-toolchain@stable` in CI. No nightly features are used |
| `flutter_rust_bridge_codegen` | **2.12.0** | Must match `flutter_rust_bridge` exactly — pinned in `app/pubspec.yaml` and as `=2.12.0` in `app/rust/Cargo.toml` |
| Python 3 | any recent | Only for `branding/make_icons.py` and `tools/gen_sites.py` |

### Linux

```
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
                 liblzma-dev fakeroot
```

### Windows

Visual Studio with the "Desktop development with C++" workload. Inno Setup 6
only if you are building the installer.

### Android

JDK 17 and the Android NDK. The Gradle build takes `ndkVersion` from
Flutter's default; cargokit cross-compiles the Rust against whatever
`ANDROID_NDK_HOME` points at.

> Heads-up: CI installs NDK `28.2.13676358` but sets `ANDROID_NDK_HOME` to
> `.../ndk/27.0.12077973`, which only resolves because that one is preinstalled
> on the runner image. It builds today and is fragile tomorrow. Locally, point
> `ANDROID_NDK_HOME` at whichever NDK you actually have.

## First build

```
git clone https://github.com/RiotTheClanker/radar-app
cd radar-app/app
flutter pub get
flutter run -d linux          # or -d windows, or a connected device
```

The first run compiles the Rust engine, which takes a few minutes. After that
it is incremental. You do **not** need to build the Rust crates by hand —
cargokit (`app/rust_builder/`) drives cargo from the Flutter build.

Nothing needs an API key, an account, or a network service of ours. If it
runs and shows a radar, your setup is correct.

## The loop

```
cd app
flutter analyze          # must be clean — CI fails on any finding
flutter test
```

```
cd rust/radar_core
cargo test
cargo clippy -- -D warnings     # advisory in CI today; keep it quiet anyway
cargo fmt
```

CI runs `flutter analyze`, `flutter test` and `cargo test --release` as
blocking checks, then builds all three platforms. Run the first three locally
and you will rarely be surprised.

## Working without the app

The engine is a normal Rust crate and can be exercised on its own — far
faster than a full Flutter rebuild when you are working on a decoder, the
classifier, or the 3D path.

```
./tools/fetch_testdata.sh                     # today's sample Level 3 files
cd rust/radar_core
cargo run --bin l2dump -- <archive2-file>
cargo run --bin l3dump -- tools/testdata/latest_N0B
cargo run --example viewtest                  # and flytest, vol3dtest,
                                              # nowcasttest, mrmstest, paltest,
                                              # terraintest, hcagrade, glmtest
```

See [docs/engine-api.md](docs/engine-api.md) for what each of those covers.

## Generated files

Four things in the tree are generated. Editing them by hand works right up
until someone regenerates.

### Regenerating the bridge

Anything under `app/lib/src/rust/` and `app/rust/src/frb_generated.rs`. Run
this after changing `app/rust/src/api/`:

```
cargo install flutter_rust_bridge_codegen --version 2.12.0
cd app
flutter_rust_bridge_codegen generate
```

Config lives in `app/flutter_rust_bridge.yaml`. Commit the regenerated files
with the change that caused them.

### The NEXRAD site table

`app/lib/data/nexrad_sites.g.dart`, from NCEI's station list:

```
curl -o tools/nexrad-stations.txt \
  https://www.ncei.noaa.gov/access/homr/file/nexrad-stations.txt
python3 tools/gen_sites.py
```

### Icons

One SVG in `branding/` is rendered to every platform size — Android mipmaps
(legacy, adaptive foreground, and the monochrome layer Android 13+ tints),
the Windows `.ico`, and the Linux hicolor tree:

```
pip install pillow cairosvg
python3 branding/make_icons.py
```

### Vendored build tooling

`app/rust_builder/cargokit/` ships with `flutter_rust_bridge`. It is excluded
from analysis and is not ours to edit.

## Conventions

**Layering is the one hard rule.** `ui/` → `state/` → `data/`. `state/` and
`data/` never import a widget and never touch a `BuildContext`. See
[docs/ui-contract.md](docs/ui-contract.md).

**Comments say why, not what.** The existing code explains the reasoning
behind non-obvious choices — why slivers go to the nearer radial, why IP
geolocation is a last resort, why the palette is global. Match that. A
comment restating the line below it is noise; a comment recording the bug
that shaped the line is the most valuable thing in the file.

**Colours and metrics live in `wx_theme.dart`.** One place, no exceptions.

**Prefer a state test to a widget test** where the behaviour is state rather
than layout. `PaneController` and `WorkspaceState` tests need no
`pumpWidget` and run in milliseconds.

**Never skip or disable a test to get CI green.**

## Branches, commits and pull requests

- Branch off `main`. One concern per branch.
- Commit messages: a short imperative summary line saying what changed and,
  where it is not obvious, why. Look at `git log` — the existing messages read
  as sentences ("Close the azimuth slivers that drew as spokes through Level
  2"), not as ticket ids.
- Open a pull request against `main`. CI must be green before merge.
- If the change is user-visible, update `RELEASE_NOTES.md` **in the same pull
  request** (see below).

## Releases

`RELEASE_NOTES.md` holds the notes for the *next* release, with a version
marker at the top:

```
<!-- version: v0.1.4 -->
```

At tag time CI reads that marker and **refuses to publish if it does not match
the tag**. So the notes and the marker are updated in the pull request that
ships the change, not afterwards. GitHub's generated commit list is appended
below whatever is written there.

Tagging `v*` builds all three platforms and attaches them to the release.

Known gap: nothing is code-signed yet. Windows shows an "unknown publisher"
warning, and Android release builds are signed with a debug key that CI
regenerates every run — so in-place upgrades fail and users must uninstall
first. One stable signing key would fix the Android half.

## Where to ask

Open an issue. For anything touching the UI layer, say which of the two
routes in [docs/ui-development.md](docs/ui-development.md) you are on — it
changes the answer.
