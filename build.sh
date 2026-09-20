#!/bin/bash
# Builds Antarium.app into ./dist.
#
#   --archive   also creates dist/Antarium-<version>.zip and its SHA-256
#   --notarize  requires Developer ID signing plus a notarytool keychain profile
#   --install   copies the verified app to /Applications and launches it
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Antarium"
BUNDLE_ID="dev.antarium.menubar"
VERSION="${VERSION:-0.1}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
BUILD_PATH=".build/antarium-release"
ARCHIVE="$DIST/$APP_NAME-$VERSION.zip"
SHA256="$ARCHIVE.sha256"
INSTALL=false
MAKE_ARCHIVE=false
NOTARIZE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=true ;;
        --archive) MAKE_ARCHIVE=true ;;
        --notarize) NOTARIZE=true; MAKE_ARCHIVE=true ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if $NOTARIZE; then
    if [[ -z "${CODESIGN_ID:-}" || "${CODESIGN_ID:-}" == "-" ]]; then
        echo "--notarize requires CODESIGN_ID='Developer ID Application: …'" >&2
        exit 2
    fi
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        echo "--notarize requires NOTARY_PROFILE created with notarytool store-credentials" >&2
        exit 2
    fi
fi

echo "==> Building (release)"
# A Swift module cache embeds its absolute path. Keeping a dedicated, cleaned
# scratch directory makes the build reproducible after the repository moves.
swift package clean --scratch-path "$BUILD_PATH"
swift build -c release --disable-sandbox --scratch-path "$BUILD_PATH"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_PATH/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Optional agent marks can be extracted from locally installed apps with
# tools/extract-icons.sh. They are deliberately not distributed in this repo.
if [[ -f Resources/pricing.json ]]; then
    cp Resources/pricing.json "$APP/Contents/Resources/pricing.json"
    echo "    bundled pricing: $(python3 -c 'import json;print(len(json.load(open("Resources/pricing.json"))["models"]))') models"
fi
if [[ -f Resources/harness.schema.json ]]; then
    cp Resources/harness.schema.json "$APP/Contents/Resources/harness.schema.json"
    echo "    bundled harness schema"
fi
if [[ -d Resources/marks ]]; then
    cp -R Resources/marks "$APP/Contents/Resources/marks"
    echo "    bundled marks: $(ls Resources/marks | tr '\n' ' ')"
fi
# App icon, plus the mark the dashboard header draws. Both are generated from
# Resources/logo/antarium.png by tools/MakeIcon.swift.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    echo "    bundled icon: AppIcon.icns"
fi
if [[ -f Resources/logo/antarium-mark.png ]]; then
    mkdir -p "$APP/Contents/Resources/logo"
    cp Resources/logo/antarium-mark.png "$APP/Contents/Resources/logo/antarium-mark.png"
fi
# Declarative harness descriptors — see README "Adding a harness".
if [[ -d Resources/harnesses ]]; then
    cp -R Resources/harnesses "$APP/Contents/Resources/harnesses"
    echo "    bundled harnesses: $(ls Resources/harnesses | sed 's/.json//' | tr '\n' ' ')"
fi
if [[ -d Resources/harness-fixtures ]]; then
    cp -R Resources/harness-fixtures "$APP/Contents/Resources/harness-fixtures"
    echo "    bundled compatibility fixtures: $(find Resources/harness-fixtures -name '*.json' | wc -l | tr -d ' ')"
fi
# Recorded quota response shapes. Without these --verify-harness-quota reports
# every descriptor as having no fixture, which is what shipped until this line
# existed: the app bundle is assembled by copying named directories, so a new
# resource directory declared in Package.swift reaches the SwiftPM bundle and
# not the app.
if [[ -d Resources/quota-fixtures ]]; then
    cp -R Resources/quota-fixtures "$APP/Contents/Resources/quota-fixtures"
    echo "    bundled quota fixtures: $(find Resources/quota-fixtures -name '*.json' | wc -l | tr -d ' ')"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Note: the hash changes on every rebuild, so macOS re-asks
# for Keychain access after each build. Sign with a Developer ID instead
# (CODESIGN_ID=...) to make the grant stick.
SIGN_ID="${CODESIGN_ID:--}"
echo "==> Signing (${CODESIGN_ID:-ad-hoc})"
if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

echo "==> Verifying application"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"

make_archive() {
    rm -f "$ARCHIVE" "$SHA256"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    shasum -a 256 "$ARCHIVE" > "$SHA256"
}

if $MAKE_ARCHIVE; then
    echo "==> Archiving $ARCHIVE"
    make_archive
fi

if $NOTARIZE; then
    echo "==> Submitting to Apple notarization"
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    # Stapling changes the app, so the distributed archive and SHA256 must be
    # rebuilt from the stapled artifact rather than the submitted pre-staple zip.
    make_archive
fi

echo "==> Built $APP"

if $INSTALL; then
    TARGET="/Applications/$APP_NAME.app"
    echo "==> Installing to $TARGET"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    open "$TARGET"
    echo "==> Running. Look for the gauge in your menu bar."
fi
