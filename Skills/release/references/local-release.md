# Local Release (Fallback)

Use this procedure only when GitHub Actions CI is unavailable.

## Prerequisites

Set environment variables (e.g., in `.env.local`):

```bash
export APP_IDENTITY="Developer ID Application: Name (TEAMID)"
export APP_STORE_CONNECT_API_KEY_P8="$(cat /path/to/AuthKey_XXXX.p8)"
export APP_STORE_CONNECT_KEY_ID="XXXXXXXXXX"
export APP_STORE_CONNECT_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Steps

### 1. Update CHANGELOG.md

Promote the `## [Unreleased]` entries to a `## [x.y.z] - YYYY-MM-DD` heading and update the link references, as in the release skill's Step 2.

### 2. Tag

```bash
git add CHANGELOG.md
git commit -m "Prepare release x.y.z"
git tag x.y.z
```

### 3. Build, Sign, and Notarize

```bash
source .env.local
./Scripts/release.sh
```

This produces `Ducko-x.y.z.zip` and `Ducko-x.y.z.dmg` (both signed, notarized, and stapled).

### 4. Generate Appcast

```bash
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

RELEASE_DIR=$(mktemp -d)
cp Ducko-x.y.z.zip "$RELEASE_DIR/"

"$SPARKLE_BIN/generate_appcast" \
  --ed-key-file /path/to/sparkle_private.key \
  --download-url-prefix "https://github.com/ducko-im/ducko/releases/download/x.y.z/" \
  -o appcast.xml \
  "$RELEASE_DIR"
rm -rf "$RELEASE_DIR"
```

The private key is in the macOS Keychain under the `ducko` account (stored by `generate_keys --account ducko`). Export with:

```bash
"$SPARKLE_BIN/generate_keys" --account ducko -x /path/to/sparkle_private.key
```

### 5. Publish

```bash
git add appcast.xml
git commit -m "Update appcast.xml for x.y.z"
git push origin main x.y.z

gh release create x.y.z \
  Ducko-x.y.z.zip \
  Ducko-x.y.z.dmg \
  appcast.xml \
  --title "Ducko x.y.z" \
  --notes-file <(awk -v ver="x.y.z" '/^## / { if (found) exit; if ($2 == ver || $2 == "[" ver "]") found=1; next } found && /^\[[^]]+\]:/ { exit } found { print }' CHANGELOG.md)
```
