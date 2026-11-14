#!/usr/bin/env bash
# =============================================================================
# notarize.sh — Notarize & staple FatCatPomodoro (app or DMG)
#
# Usage:
#   NOTARYTOOL_KEYCHAIN_PROFILE=FatCatPomodoro-notarize ./scripts/notarize.sh
#   NOTARYTOOL_KEYCHAIN_PROFILE=FatCatPomodoro-notarize ./scripts/notarize.sh build/FatCatPomodoro-1.0.0.dmg
#
# With no argument the app at build/export/FatCatPomodoro.app is notarized.
#
# Alternatively, export credentials instead of using a keychain profile:
#   export APPLE_ID="you@example.com"
#   export APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="NZJ6XP9B66"
TARGET="${1:-$REPO_ROOT/build/export/FatCatPomodoro.app}"

if [ ! -e "$TARGET" ]; then
    echo "❌  Error: $TARGET not found."
    exit 1
fi

case "$TARGET" in
    *.app)  KIND="app"  ; TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")" ;;
    *.dmg)  KIND="dmg"  ; TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")" ;;
    *)      echo "❌  Unsupported target (expected .app or .dmg): $TARGET"; exit 1 ;;
esac

echo "══════════════════════════════════════════════════"
echo " FatCatPomodoro — Notarize & Staple"
echo "══════════════════════════════════════════════════"

# ── Credential resolution ─────────────────────────────────────────────────────
if [ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]; then
    echo "  Auth   : Keychain profile → $NOTARYTOOL_KEYCHAIN_PROFILE"
    NOTARY_AUTH=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
    echo "  Auth   : Apple ID → $APPLE_ID"
    NOTARY_AUTH=(
        --apple-id "$APPLE_ID"
        --team-id "$TEAM_ID"
        --password "$APP_SPECIFIC_PASSWORD"
    )
else
    echo "❌  Error: No notarytool credentials found."
    echo "    export NOTARYTOOL_KEYCHAIN_PROFILE=\"FatCatPomodoro-notarize\""
    exit 1
fi

echo "  Kind   : $KIND"
echo "  Target : $TARGET"
echo ""

# ── Step 1: Prepare submission ────────────────────────────────────────────────
if [ "$KIND" = "app" ]; then
    SUBMIT="$REPO_ROOT/build/FatCatPomodoro-notarize.zip"
    echo "▶ Step 1/4 — Zipping .app for submission …"
    rm -f "$SUBMIT"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    echo "✓ Zipped: $SUBMIT"
else
    SUBMIT="$TARGET"
    echo "▶ Step 1/4 — Submitting DMG directly …"
fi
echo ""

# ── Step 2: Submit to Apple notary service ────────────────────────────────────
echo "▶ Step 2/4 — Submitting to Apple notary service (this can take 1–5 min) …"
SUBMISSION_OUTPUT=$(xcrun notarytool submit "$SUBMIT" \
    "${NOTARY_AUTH[@]}" \
    --wait \
    --output-format json)

STATUS=$(echo "$SUBMISSION_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))")
SUBMISSION_ID=$(echo "$SUBMISSION_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))")

echo ""
echo "  Submission ID : $SUBMISSION_ID"
echo "  Status        : $STATUS"
echo ""

if [ "$STATUS" != "Accepted" ]; then
    echo "❌  Notarization failed! Fetching log …"
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" 2>&1 || true
    exit 1
fi

echo "✓ Notarization accepted."
echo ""

# ── Step 3: Staple ticket ─────────────────────────────────────────────────────
echo "▶ Step 3/4 — Stapling ticket …"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "✓ Ticket stapled."
echo ""

# ── Step 4: Gatekeeper assessment ─────────────────────────────────────────────
echo "▶ Step 4/4 — Verifying Gatekeeper assessment …"
if [ "$KIND" = "app" ]; then
    spctl --assess --type execute --verbose=2 "$TARGET"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
echo ""
echo "══════════════════════════════════════════════════"
echo "✅  Notarization & stapling complete."
echo "    $TARGET"
echo "══════════════════════════════════════════════════"
