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

INSTALLED_KB=$(du -ks "$STAGE/$PKG/usr" | cut -f1)

cat > "$STAGE/$PKG/DEBIAN/control" <<CONTROL
Package: radar-app
Version: $VERSION
Section: science
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libstdc++6, zlib1g, libbz2-1.0
Installed-Size: $INSTALLED_KB
Maintainer: radar-app contributors
Description: Free weather radar with on-device NEXRAD processing
 Level 2 and Level 3 NEXRAD decoding, derived products, 3D storm volumes,
 lightning, warnings and on-device future radar. No subscription, no
 account, no server: every calculation runs locally.
CONTROL

cat > "$STAGE/$PKG/usr/share/applications/radar-app.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Radar
Comment=Free weather radar with on-device NEXRAD processing
Exec=/usr/bin/radar-app
Icon=weather-storm
Terminal=false
Categories=Science;Education;
DESKTOP

fakeroot dpkg-deb --build "$STAGE/$PKG" >/dev/null
mkdir -p dist
mv "$STAGE/$PKG.deb" dist/
rm -rf "$STAGE"
echo "dist/$PKG.deb"
