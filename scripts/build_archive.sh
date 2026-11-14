#!/usr/bin/env bash
# =============================================================================
# build_archive.sh — Archive & sign FatCatPomodoro for Developer ID distribution
#
# Usage: ./scripts/build_archive.sh
#
# Builds the direct-download flavour (FATCAT_DIRECT, no StoreKit) and signs it
# manually with Developer ID. Signing is done inside-out without --deep because
# Sparkle's XPC services require their own entitlements.
#
# Prerequisites:
#   • Xcode 16+
#   • "Developer ID Application: Ky Anh Pham (NZJ6XP9B66)" cert in keychain
#     Verify: security find-identity -v -p codesigning | grep "Developer ID Application"
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/FatCatPomodoro.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/FatCatPomodoro.app"
APP_EXPORT="$EXPORT_DIR/FatCatPomodoro.app"
SCHEME="FatCatPomodoro"
PROJECT="$REPO_ROOT/FatCatPomodoro.xcodeproj"
ENTITLEMENTS="$REPO_ROOT/Sources/FatCatPomodoro/FatCatPomodoro.entitlements"
SIGN_IDENTITY="Developer ID Application: Ky Anh Pham (NZJ6XP9B66)"
SPARKLE="$APP_EXPORT/Contents/Frameworks/Sparkle.framework"

echo "══════════════════════════════════════════════════"
echo " FatCatPomodoro — Archive & Sign (Direct)"
echo "══════════════════════════════════════════════════"
echo "  Project  : $PROJECT"
echo "  Scheme   : $SCHEME"
echo "  Archive  : $ARCHIVE"
echo "  Export   : $EXPORT_DIR"
echo "  Identity : $SIGN_IDENTITY"
echo "  Flavour  : FATCAT_DIRECT (no StoreKit)"
echo ""

# Verify the signing certificate is present before we start
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "❌  Developer ID Application certificate not found in keychain."
    echo "    Install it from developer.apple.com → Certificates."
    exit 1
fi

# Clean previous artefacts
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

# ── Step 1: Archive (signing disabled — applied manually in step 3) ───────────
echo "▶ Step 1/4 — Archiving without signing …"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM=NZJ6XP9B66 \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="FATCAT_DIRECT" 2>&1 | grep -E "error:|warning:| ARCHIVE |✓|❌" || true

if [ ! -d "$APP_IN_ARCHIVE" ]; then
    echo "❌  Archive failed — app not found at $APP_IN_ARCHIVE"
    echo "    Re-run without the grep filter to see full xcodebuild output."
    exit 1
fi
echo "✓ Archive created."
echo ""

# ── Step 2: Copy app to export dir ───────────────────────────────────────────
echo "▶ Step 2/4 — Copying to export directory …"
ditto "$APP_IN_ARCHIVE" "$APP_EXPORT"

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_EXPORT/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_EXPORT/Contents/Info.plist")
echo "✓ Copied: $APP_EXPORT (version $APP_VERSION, build $APP_BUILD)"
echo ""

# ── Step 3: Sign with Developer ID Application (inside-out) ──────────────────
echo "▶ Step 3/4 — Signing with Developer ID Application …"

sign() {
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
}

# Sparkle must be signed explicitly and without --deep. Updater.app and the XPC
# services live inside the framework, so they are re-signed before the framework.
if [ -d "$SPARKLE" ]; then
    echo "  · Sparkle.framework"
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
else
    echo "❌  Sparkle.framework not found in $APP_EXPORT — direct build cannot update."
    exit 1
fi

# Any other embedded frameworks/dylibs (e.g. LicenseKit if it becomes dynamic).
if [ -d "$APP_EXPORT/Contents/Frameworks" ]; then
    for item in "$APP_EXPORT/Contents/Frameworks/"*; do
        [ "$item" = "$SPARKLE" ] && continue
        case "$item" in
            *.framework|*.dylib)
                echo "  · $(basename "$item")"
                sign "$item"
                ;;
        esac
    done
fi

# Sign the .app bundle itself with entitlements + hardened runtime.
sign --entitlements "$ENTITLEMENTS" "$APP_EXPORT"

echo "✓ Signed."
echo ""

# ── Step 4: Verify signature ─────────────────────────────────────────────────
echo "▶ Step 4/4 — Verifying code signature …"
codesign --verify --deep --strict --verbose=2 "$APP_EXPORT"
echo ""
codesign -dv --entitlements :- "$APP_EXPORT" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Timestamp|Runtime|com\.apple\.security|spks|spki" | head -30
echo ""

# Guard: the direct build must not link StoreKit.
if otool -L "$APP_EXPORT/Contents/MacOS/FatCatPomodoro" | grep -q "/StoreKit.framework"; then
    echo "❌  StoreKit.framework is linked into the direct build."
    exit 1
fi
echo "✓ No StoreKit.framework linked (direct build)."
echo ""

echo "══════════════════════════════════════════════════"
echo "✅  Build complete."
echo "    App     : $APP_EXPORT"
echo "    Version : $APP_VERSION ($APP_BUILD)"
echo ""
echo "Next steps:"
echo "  1. Run: NOTARYTOOL_KEYCHAIN_PROFILE=FatCatPomodoro-notarize ./scripts/notarize.sh"
echo "  2. Run: ./scripts/make_dmg.sh"
echo "══════════════════════════════════════════════════"
