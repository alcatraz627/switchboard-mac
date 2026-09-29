#!/usr/bin/env bash
# Build Switchboard.app and run it, install it, or package it for a release.
#
#   scripts/build.sh              build into build/ and launch it (replaces a running copy)
#   scripts/build.sh --install    build, copy to ~/Applications, start at login (LaunchAgent)
#   scripts/build.sh --uninstall  stop it, remove the LaunchAgent and the installed app
#   scripts/build.sh --package    build and zip into dist/ with a SHA-256 file (no launch)
#   scripts/build.sh --status     what is running, what is installed, is the build stale
#   scripts/build.sh --logs       follow the app log
#
# Needs only the Xcode command line tools (swiftc) and python3.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_NAME="Switchboard"
BUNDLE_ID="io.github.alcatraz627.switchboard"
BUILD_APP="$ROOT/build/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Switchboard/switchboard.log"
MODE="${1:-}"

# Every Swift file in Sources/ is part of the one module, so there is no list to keep in step.
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
src_hash() { cat "${SOURCES[@]}" "$ROOT"/Resources/lib/*.py | shasum | cut -c1-10; }

# Old builds go to the Trash where the `trash` command exists (macOS 15+, or Homebrew).
discard() { if command -v trash >/dev/null 2>&1; then trash "$@"; else rm -rf "$@"; fi; }

stop_running() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x "$APP_NAME" >/dev/null || return 0; sleep 0.3; done
}

case "$MODE" in
  --logs) mkdir -p "$(dirname "$LOG")"; touch "$LOG"; exec tail -f "$LOG" ;;
  --status)
    echo "Running:   $(pgrep -x "$APP_NAME" | tr '\n' ' ' || true)"
    echo "Installed: $([[ -d "$INSTALL_APP" ]] && echo "$INSTALL_APP" || echo no)"
    echo "At login:  $([[ -f "$PLIST" ]] && echo "yes ($PLIST)" || echo no)"
    if [[ -f "$ROOT/build/.src-hash" ]]; then
      [[ "$(cat "$ROOT/build/.src-hash")" == "$(src_hash)" ]] && echo "Build:     current" || echo "Build:     STALE, run scripts/build.sh"
    fi
    exit 0 ;;
  --uninstall)
    stop_running
    [[ -f "$PLIST" ]] && discard "$PLIST" 2>/dev/null || true
    [[ -d "$INSTALL_APP" ]] && discard "$INSTALL_APP" 2>/dev/null || true
    echo "Uninstalled (settings in ~/Library/Application Support/Switchboard are kept)."
    exit 0 ;;
esac

# ── Build the bundle ────────────────────────────────────────────────────────
echo "Building $APP_NAME $VERSION"
STAGE="$ROOT/build/.stage"
[[ -d "$STAGE" ]] && discard "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/lib"

/usr/bin/swiftc -O "${SOURCES[@]}" -o "$STAGE/Contents/MacOS/$APP_NAME"
cp -f "$ROOT"/Resources/lib/*.py "$STAGE/Contents/Resources/lib/"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS shows the name of your Wi-Fi network only to apps with Location access. Switchboard uses it for that name and nothing else.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>A note can carry a reminder. Switchboard adds it to Reminders and removes it when you clear it, and touches no other reminder.</string>
  <key>NSRemindersUsageDescription</key><string>A note can carry a reminder. Switchboard adds it to Reminders and removes it when you clear it, and touches no other reminder.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Switchboard lists your paired Bluetooth devices so you can connect and disconnect them from the panel.</string>
</dict>
</plist>
EOF
# Ad-hoc signature: enough to run locally; see docs/releasing.md for Gatekeeper.
/usr/bin/codesign --sign - --force --deep "$STAGE" >/dev/null
[[ -d "$BUILD_APP" ]] && discard "$BUILD_APP"
mv -f "$STAGE" "$BUILD_APP"
src_hash > "$ROOT/build/.src-hash"
echo "  built $BUILD_APP"

case "$MODE" in
  --package)
    mkdir -p "$ROOT/dist"
    ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"
    [[ -f "$ZIP" ]] && discard "$ZIP"
    (cd "$ROOT/build" && /usr/bin/ditto -c -k --keepParent "$APP_NAME.app" "$ZIP")
    (cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
    echo "  packaged $ZIP"
    ;;
  --install)
    stop_running
    mkdir -p "$HOME/Applications" "$(dirname "$PLIST")" "$(dirname "$LOG")"
    [[ -d "$INSTALL_APP" ]] && discard "$INSTALL_APP"
    cp -R "$BUILD_APP" "$INSTALL_APP"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$INSTALL_APP/Contents/MacOS/$APP_NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "  installed $INSTALL_APP, starts at login"
    ;;
  *)
    stop_running
    # A clean environment, like launchd gives the installed app: open passes the
    # caller's on, and from an agent session that means its variables and tokens.
    env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL="${SHELL:-/bin/zsh}" PATH=/usr/bin:/bin:/usr/sbin:/sbin open "$BUILD_APP"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null && echo "  running (pid $(pgrep -x "$APP_NAME" | head -1))" \
      || echo "  did not start, see: scripts/build.sh --logs"
    ;;
esac
