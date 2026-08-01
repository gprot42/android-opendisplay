#!/bin/zsh
# Build, sign, and install the Mac OpenDisplay app into /Applications.
#
# Usage:
#   ./install-mac.sh                 # Debug → /Applications/OpenDisplay Dev.app
#   ./install-mac.sh --release       # Release → /Applications/OpenDisplay.app
#   ./install-mac.sh --no-build      # Re-sign + copy an existing build only
#   ./install-mac.sh --open          # Launch after install
#   ./install-mac.sh --reset-tcc     # Reset Screen Recording for this app’s bundle ID
#
# Signing (first match wins):
#   1. CODE_SIGN_IDENTITY env / .env
#   2. "Developer ID Application: …" on the keychain
#   3. "Apple Development: …" / "Mac Development: …"
#   4. Ad-hoc (-) — works for local runs; Screen Recording may not stick across rebuilds
#
# DEVELOPMENT_TEAM from .env is used when Xcode automatic signing succeeds;
# if no Mac Development cert is available we build unsigned then codesign.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=Debug
DO_BUILD=1
DO_OPEN=0
DO_RESET_TCC=0
INSTALL_NAME=""   # override destination basename

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|-r) CONFIG=Release; shift ;;
    --debug|-d)   CONFIG=Debug; shift ;;
    --no-build)   DO_BUILD=0; shift ;;
    --open)       DO_OPEN=1; shift ;;
    --reset-tcc)  DO_RESET_TCC=1; shift ;;
    --name)       INSTALL_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

# --- env ---
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

if [[ -z "${INSTALL_NAME}" ]]; then
  if [[ "$CONFIG" == "Debug" ]]; then
    INSTALL_NAME="OpenDisplay Dev.app"
  else
    INSTALL_NAME="OpenDisplay.app"
  fi
fi
DEST="/Applications/${INSTALL_NAME}"

BUNDLE_ID="com.peetzweg.opensidecar.mac"
[[ "$CONFIG" == "Debug" ]] && BUNDLE_ID="com.peetzweg.opensidecar.mac.debug"

# Prefer local derived data path used by this script; fall back to default DerivedData.
DERIVED="${DERIVED_DATA_PATH:-$PWD/build}"
APP_SRC="${DERIVED}/Build/Products/${CONFIG}/OpenDisplay.app"

log() { print -r -- "▸ $*"; }
die() { print -r -- "error: $*" >&2; exit 1; }

# --- pick codesign identity ---
pick_identity() {
  if [[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY}" != "-" ]]; then
    print -r -- "$CODE_SIGN_IDENTITY"
    return
  fi
  local list
  list=$(security find-identity -v -p codesigning 2>/dev/null || true)
  local id
  id=$(print -r -- "$list" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  [[ -n "$id" ]] && { print -r -- "$id"; return; }
  id=$(print -r -- "$list" | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
  [[ -n "$id" ]] && { print -r -- "$id"; return; }
  id=$(print -r -- "$list" | sed -n 's/.*"\(Mac Development: .*\)"/\1/p' | head -1)
  [[ -n "$id" ]] && { print -r -- "$id"; return; }
  print -r -- "-"
}

IDENTITY=$(pick_identity)
log "configuration: $CONFIG"
log "destination:   $DEST"
log "bundle id:     $BUNDLE_ID"
log "codesign:      $IDENTITY"

# --- build ---
if [[ "$DO_BUILD" -eq 1 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    log "generating Xcode project…"
    ./generate.sh
  elif [[ ! -d OpenSidecar.xcodeproj ]]; then
    die "OpenSidecar.xcodeproj missing and xcodegen not installed"
  fi

  # SPM stores absolute artifact paths in workspace-state.json. If the repo
  # was renamed/moved (e.g. opendisplay-android → android-opendisplay), those
  # paths go stale and xcodebuild fails looking for Sparkle.xcframework.
  if [[ -f "$DERIVED/SourcePackages/workspace-state.json" ]]; then
    if ! grep -qF "$PWD" "$DERIVED/SourcePackages/workspace-state.json" 2>/dev/null; then
      log "stale SPM package paths (repo moved/renamed) — resetting SourcePackages…"
      rm -rf "$DERIVED/SourcePackages" "$DERIVED/Build/Intermediates.noindex/XCBuildData"
    fi
  fi

  log "resolving Swift packages…"
  xcodebuild \
    -project OpenSidecar.xcodeproj \
    -scheme OpenSidecarMac \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -resolvePackageDependencies \
    >/dev/null

  log "building OpenSidecarMac ($CONFIG)…"
  # Build without requiring a Mac Development cert; we re-sign after.
  # Don't mask xcodebuild failure behind `tail` (zsh pipestatus is 1-indexed).
  set +e
  xcodebuild \
    -project OpenSidecar.xcodeproj \
    -scheme OpenSidecarMac \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    build 2>&1 | tail -40
  build_status=${pipestatus[1]}
  set -e
  [[ $build_status -eq 0 ]] || die "xcodebuild failed (exit $build_status)"

  [[ -d "$APP_SRC" ]] || die "build product not found: $APP_SRC"
else
  # Allow --no-build with default Xcode DerivedData if local build/ is empty.
  if [[ ! -d "$APP_SRC" ]]; then
    local_dd=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/${CONFIG}/OpenDisplay.app" -type d 2>/dev/null | head -1 || true)
    [[ -n "$local_dd" ]] && APP_SRC="$local_dd"
  fi
  [[ -d "$APP_SRC" ]] || die "no existing build at $APP_SRC (omit --no-build to compile)"
  log "using existing build: $APP_SRC"
fi

# --- sign ---
sign_tree() {
  local app="$1" id="$2"
  if [[ "$id" == "-" ]]; then
    log "ad-hoc signing (Screen Recording may not stick across rebuilds)…"
    codesign --force --deep --sign - "$app"
    return
  fi
  log "signing with $id…"
  # Inner frameworks/dylibs first, then the bundle.
  if [[ -d "$app/Contents/Frameworks" ]]; then
    find "$app/Contents/Frameworks" \( -name '*.framework' -o -name '*.dylib' \) -print0 \
      | while IFS= read -r -d '' f; do
          codesign --force --options runtime --timestamp --sign "$id" "$f" 2>/dev/null \
            || codesign --force --sign "$id" "$f" 2>/dev/null \
            || true
        done
  fi
  local ent="Mac/OpenSidecarMac.entitlements"
  if [[ -f "$ent" ]]; then
    codesign --force --deep --options runtime --timestamp \
      --entitlements "$ent" --sign "$id" "$app" \
      || codesign --force --deep --sign "$id" "$app"
  else
    codesign --force --deep --options runtime --timestamp --sign "$id" "$app" \
      || codesign --force --deep --sign "$id" "$app"
  fi
}

# Sign a copy so we don't mutate DerivedData while Xcode might be using it.
STAGE=$(mktemp -d /tmp/opendisplay-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_SRC" "$STAGE/OpenDisplay.app"
sign_tree "$STAGE/OpenDisplay.app" "$IDENTITY"
codesign -dv --verbose=2 "$STAGE/OpenDisplay.app" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|Signature=' || true

# --- install into /Applications ---
log "stopping running OpenDisplay (if any)…"
killall OpenDisplay 2>/dev/null || true
sleep 0.3

install_copy() {
  local src="$1" dest="$2"
  if [[ -w /Applications ]] || [[ -w "$(dirname "$dest")" ]]; then
    rm -rf "$dest"
    cp -R "$src" "$dest"
    return
  fi
  if sudo -n true 2>/dev/null; then
    sudo rm -rf "$dest"
    sudo cp -R "$src" "$dest"
    sudo chown -R root:wheel "$dest"
    return
  fi
  # GUI admin prompt
  log "requesting admin rights to write $dest…"
  osascript -e "do shell script \"rm -rf $(printf %q "$dest") && cp -R $(printf %q "$src") $(printf %q "$dest") && chown -R root:wheel $(printf %q "$dest")\" with administrator privileges"
}

log "installing → $DEST"
install_copy "$STAGE/OpenDisplay.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# --- optional TCC reset ---
if [[ "$DO_RESET_TCC" -eq 1 ]]; then
  log "resetting Screen Recording TCC for $BUNDLE_ID…"
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
  log "re-enable “${INSTALL_NAME%.app}” under System Settings → Privacy & Security → Screen Recording"
fi

log "installed: $DEST"
print -r -- ""
print -r -- "Next:"
print -r -- "  1. System Settings → Privacy & Security → Screen Recording → enable “${INSTALL_NAME%.app}”"
print -r -- "  2. open \"$DEST\""
print -r -- "  3. Connect to your Android device (USB debugging + adb recommended)"
print -r -- ""
print -r -- "Logs: /tmp/opensidecar-mac.log"

if [[ "$DO_OPEN" -eq 1 ]]; then
  open "$DEST"
  log "launched"
fi
