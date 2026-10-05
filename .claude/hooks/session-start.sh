#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: makes sure the Flutter SDK
# (pinned to CI's FLUTTER_VERSION) and stable Rust with clippy/rustfmt are on
# PATH, and fetches Dart and cargo dependencies, so `flutter analyze`,
# `flutter test`, `cargo test` and `cargo clippy` work straight away.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# One source of truth for the Flutter version: the CI workflow.
FLUTTER_VERSION="$(sed -n "s/^ *FLUTTER_VERSION: *'\([^']*\)'.*/\1/p" "$ROOT/.github/workflows/build.yml" | head -1)"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.8}"
FLUTTER_HOME="$HOME/flutter-$FLUTTER_VERSION"

# --- Rust -------------------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup component add clippy rustfmt >/dev/null 2>&1 || true

# --- Flutter ----------------------------------------------------------------
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  tmp="$(mktemp -d)"
  curl -sSfL -o "$tmp/flutter.tar.xz" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -xJf "$tmp/flutter.tar.xz" -C "$tmp"
  rm -rf "$FLUTTER_HOME"
  mv "$tmp/flutter" "$FLUTTER_HOME"
  rm -rf "$tmp"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"
# The SDK is extracted as root; git refuses to read it without this.
git config --global --get-all safe.directory | grep -qxF "$FLUTTER_HOME" \
  || git config --global --add safe.directory "$FLUTTER_HOME"
flutter config --no-analytics >/dev/null 2>&1 || true
dart --disable-analytics >/dev/null 2>&1 || true

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$FLUTTER_HOME/bin:$HOME/.cargo/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# --- Dependencies -----------------------------------------------------------
(cd "$ROOT/app" && flutter pub get)
(cd "$ROOT/rust/radar_core" && cargo fetch)
(cd "$ROOT/app/rust" && cargo fetch)
