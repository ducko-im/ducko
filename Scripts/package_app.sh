#!/usr/bin/env bash
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/version.env"

# Derive version from git tag and build number from commit count.
MARKETING_VERSION=${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo "1")

EXEC_NAME=${EXEC_NAME:-DuckoApp}
CLI_NAME=${CLI_NAME:-DuckoCLI}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-26.0}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}

if [[ "${ARCHES:-arm64}" != "arm64" ]]; then
  echo "ERROR: Ducko supports Apple Silicon only (arm64)." >&2
  exit 1
fi

swift build -c "$CONF" --arch arm64
BIN_DIR=$(swift build -c "$CONF" --arch arm64 --show-bin-path)

APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tobias Hagemann. All rights reserved.</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/tobihagemann/ducko/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>SaoWoBwGAvFPeUCkM7sp8mWO3CdwWa/Yw78vZ5xGDHk=</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>DuckoBuildConfiguration</key><string>${CONF}</string>
</dict>
</plist>
PLIST

verify_binary_arches() {
  local binary="$1"
  local actual
  actual=$(lipo -archs "$binary")
  if [[ "$actual" != "arm64" ]]; then
    echo "ERROR: $binary arch mismatch (expected: arm64, actual: ${actual})" >&2
    exit 1
  fi
}

install_binary() {
  local name="$1"
  local dest="$2"
  local src="$BIN_DIR/$name"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: Missing ${name} build at ${src}" >&2
    exit 1
  fi
  cp "$src" "$dest"
  chmod +x "$dest"
  verify_binary_arches "$dest"
}

# Install main app binary.
install_binary "$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"

# Install CLI binary into Resources (for "Install Command Line Tools..." menu item).
install_binary "$CLI_NAME" "$APP/Contents/Resources/ducko"

# Copy precompiled Assets.car (Liquid Glass icon).
if [[ -f "$ROOT/Resources/Assets.car" ]]; then
  cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
fi

cp -R "$ROOT/Resources/ThirdPartyLicenses" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# Embed frameworks if any exist in the build folder.
if compgen -G "${BIN_DIR}/"*.framework >/dev/null; then
  cp -R "${BIN_DIR}/"*.framework "$APP/Contents/Frameworks/"
  chmod -R a+rX "$APP/Contents/Frameworks"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXEC_NAME"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-"$ROOT/Resources/Entitlements.plist"}

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

# Sign loose executables outside Frameworks (the embedded `ducko` CLI in Resources). Signing the
# app bundle seals them as resources but keeps their linker ad-hoc signature, which notarization
# rejects: every Mach-O needs the Developer ID signature, hardened runtime, and a secure timestamp.
while IFS= read -r -d '' bin; do
  codesign "${CODESIGN_ARGS[@]}" "$bin"
done < <(find "$APP/Contents/Resources" -type f -perm -111 -print0)

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
