#!/usr/bin/env bash
# Build a .deb from the release Linux bundle.
#   ./packaging/build-deb.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
ARCH="$(dpkg --print-architecture)"
BUNDLE="app/build/linux/x64/release/bundle"
STAGE="$(mktemp -d)"
PKG="radar-app_${VERSION}_${ARCH}"

if [ ! -x "$BUNDLE/radar_app" ]; then
  echo "No release bundle. Run: (cd app && flutter build linux --release)" >&2
  exit 1
fi

install -d "$STAGE/$PKG/DEBIAN" \
           "$STAGE/$PKG/usr/lib/radar-app" \
           "$STAGE/$PKG/usr/bin" \
           "$STAGE/$PKG/usr/share/applications" \
           "$STAGE/$PKG/usr/share/metainfo"

cp -r "$BUNDLE"/. "$STAGE/$PKG/usr/lib/radar-app/"
ln -s ../lib/radar-app/radar_app "$STAGE/$PKG/usr/bin/radar-app"

# Our own icon, at every size the shell might ask for. Previously the
# desktop entry pointed at the theme icon "weather-storm", which is not in
# every icon theme -- where it was missing the launcher showed a blank.
for SZ in 16 24 32 48 64 128 256 512; do
  install -Dm644 "packaging/icons/hicolor/${SZ}x${SZ}/apps/radar-app.png" \
    "$STAGE/$PKG/usr/share/icons/hicolor/${SZ}x${SZ}/apps/radar-app.png"
done
install -Dm644 branding/icon.svg \
  "$STAGE/$PKG/usr/share/icons/hicolor/scalable/apps/radar-app.svg"

INSTALLED_KB=$(du -ks "$STAGE/$PKG/usr" | cut -f1)

cat > "$STAGE/$PKG/DEBIAN/control" <<CONTROL
Package: radar-app
Version: $VERSION
Section: science
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libstdc++6, zlib1g, libbz2-1.0
Installed-Size: $INSTALLED_KB
Maintainer: Taa'a Yuku Radar contributors
Description: Free weather radar with on-device NEXRAD processing
 Level 2 and Level 3 NEXRAD decoding, derived products, 3D storm volumes,
 lightning, warnings and on-device future radar. No subscription, no
 account, no server: every calculation runs locally.
CONTROL

cat > "$STAGE/$PKG/usr/share/applications/radar-app.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Taa'a Yuku Radar
Comment=Free weather radar with on-device NEXRAD processing
Exec=/usr/bin/radar-app
Icon=radar-app
Terminal=false
Categories=Science;Education;
Keywords=weather;radar;nexrad;storm;forecast;lightning;
StartupWMClass=dev.radarapp.radar_app
DESKTOP

fakeroot dpkg-deb --build "$STAGE/$PKG" >/dev/null
mkdir -p dist
mv "$STAGE/$PKG.deb" dist/
rm -rf "$STAGE"
echo "dist/$PKG.deb"
