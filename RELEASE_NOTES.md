<!-- version: v0.1.3 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

The app has a name and a face.

**Taa'a Yuku Radar** — Yaqui (Yoeme): *taa'a*, the sun, close to *ta'a*, to
know; and *yuku*, the rain. Used with the blessing of a Yaqui speaker.

Until now the app answered to four different names depending on where you
looked — `radar_app` on the Android launcher, `Radar` in the desktop entry,
`RadarApp` in the Windows install path, and "A new Flutter project." in its
own metadata — while wearing the stock Flutter logo on every platform. All of
that is gone.

### What's new

- **The name**, everywhere one is shown: launcher, window titles, installer,
  desktop entry. The Android launcher shows **TY Radar**, since the full name
  is too long to sit under an icon without being cut off.
- **An icon of its own** — a radar sweep over range rings with a storm cell in
  the reflectivity scale. Drawn once as geometry and rendered to every target:
  Android densities, an adaptive icon, a monochrome layer for Android 13+
  themed icons, a multi-size Windows `.ico`, and the Linux hicolor set. The
  `.deb` now ships its own icon instead of borrowing `weather-storm` from your
  icon theme, which was missing on many systems and left a blank in the
  launcher.
- **A proper application ID**, `io.github.riottheclanker.taayuku`, replacing
  the Flutter template placeholder. Done now because it can never change once
  a signed release ships.
- **A polite User-Agent.** Requests to NOAA and the tile servers now identify
  the app, its version, and where to reach the author, which is what those
  services ask for.

### ⚠️ Upgrading on Android

The application ID changed, and Android treats that as a **different app**.
This APK installs *alongside* 0.1.2 rather than replacing it, so you will see
two icons.

**Uninstall the old one** — it is the one still labelled `radar_app`. The new
one reads **TY Radar**.

This is a one-time move, done deliberately before any signed release, because
after that the ID is fixed permanently.

### Install

- **Debian / Ubuntu** — `sudo apt install ./radar-app_0.1.3_amd64.deb`
- **Windows** — run `radar-app-0.1.3-windows-setup.exe`
- **Android** — take the APK matching your device's ABI; `arm64-v8a` for
  essentially anything modern

### Still true

Nothing is code-signed yet, so Windows shows an "unknown publisher" warning
and Android asks about installing from an unknown source. Android release
builds still use a debug key that CI regenerates each run, so in-place
upgrades between builds fail and need an uninstall first. Stable signing is
next.

Linux and Android `arm64-v8a` are tested on real hardware. The Windows build
comes out of CI and has not been smoke-tested.
