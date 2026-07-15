#!/usr/bin/env bash
# ============================================================
# notarize.sh — Notarize + staple a Spacie DMG
#
# Requires: Apple Developer account, Xcode 14+ (notarytool).
# The DMG must contain an already Developer-ID-signed .app
# (see scripts/codesign-app.sh).
#
# Credentials — first match wins:
#   1. App Store Connect API key (preferred, robust for CI):
#        NOTARY_API_KEY_PATH  — path to the .p8 private key file
#        NOTARY_API_KEY_ID    — Key ID (e.g. 5N957RWTGL)
#        NOTARY_API_ISSUER    — Issuer UUID
#   2. Stored keychain profile:
#        NOTARY_PROFILE=AC_PASSWORD
#   3. Apple ID + app-specific password:
#        NOTARIZE_APPLE_ID, NOTARIZE_TEAM_ID, NOTARIZE_PASSWORD
#
# Usage: ./scripts/notarize.sh <dmg-path>
# ============================================================

set -euo pipefail

DMG_PATH="${1:?Usage: notarize.sh <dmg-path>}"

echo "==> Notarizing ${DMG_PATH}"

if [ -n "${NOTARY_API_KEY_PATH:-}" ] && [ -n "${NOTARY_API_KEY_ID:-}" ] && [ -n "${NOTARY_API_ISSUER:-}" ]; then
    xcrun notarytool submit "${DMG_PATH}" \
        --key "${NOTARY_API_KEY_PATH}" \
        --key-id "${NOTARY_API_KEY_ID}" \
        --issuer "${NOTARY_API_ISSUER}" \
        --wait
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
elif [ -n "${NOTARIZE_APPLE_ID:-}" ] && [ -n "${NOTARIZE_TEAM_ID:-}" ] && [ -n "${NOTARIZE_PASSWORD:-}" ]; then
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${NOTARIZE_APPLE_ID}" \
        --team-id "${NOTARIZE_TEAM_ID}" \
        --password "${NOTARIZE_PASSWORD}" \
        --wait
else
    echo "Error: no notarization credentials." >&2
    echo "Set NOTARY_API_KEY_PATH+NOTARY_API_KEY_ID+NOTARY_API_ISSUER, or NOTARY_PROFILE, or NOTARIZE_APPLE_ID+NOTARIZE_TEAM_ID+NOTARIZE_PASSWORD." >&2
    exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature -v "${DMG_PATH}" || true

echo "notarize.sh: done."
