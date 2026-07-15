#!/usr/bin/env bash
# ============================================================
# codesign-app.sh — Developer ID sign Spacie.app (Sparkle-aware)
#
# Sparkle ships helper executables inside Sparkle.framework
# (XPC services, Autoupdate, Updater.app) that MUST be signed
# individually, inner-to-outer, with Hardened Runtime — a plain
# `codesign --deep` on the app is not sufficient / not recommended.
#
# Usage:
#   ./scripts/codesign-app.sh <app-bundle> <signing-identity> <entitlements-plist>
#
# Example:
#   ./scripts/codesign-app.sh build/export/Spacie.app \
#       "Developer ID Application: Alex Gladkov (7N3PU42797)" \
#       Spacie/Spacie.entitlements
# ============================================================

set -euo pipefail

APP="${1:?Usage: codesign-app.sh <app-bundle> <identity> <entitlements>}"
IDENTITY="${2:?Usage: codesign-app.sh <app-bundle> <identity> <entitlements>}"
ENTITLEMENTS="${3:?Usage: codesign-app.sh <app-bundle> <identity> <entitlements>}"

CODESIGN_FLAGS=(--force --timestamp --options runtime --sign "${IDENTITY}")

echo "==> Signing with identity: ${IDENTITY}"

SPARKLE_FW="${APP}/Contents/Frameworks/Sparkle.framework"

if [ -d "${SPARKLE_FW}" ]; then
    echo "==> Signing Sparkle helper executables (inner-to-outer)"
    VER="${SPARKLE_FW}/Versions/B"

    # XPC services
    for xpc in "${VER}/XPCServices/"*.xpc; do
        [ -e "${xpc}" ] || continue
        echo "    codesign ${xpc}"
        codesign "${CODESIGN_FLAGS[@]}" "${xpc}"
    done

    # Autoupdate + Updater.app (the relauncher UI)
    [ -e "${VER}/Autoupdate" ]   && codesign "${CODESIGN_FLAGS[@]}" "${VER}/Autoupdate"
    if [ -d "${VER}/Updater.app" ]; then
        codesign "${CODESIGN_FLAGS[@]}" "${VER}/Updater.app"
    fi

    # The framework itself
    codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}"
fi

# Any remaining bundled frameworks / dylibs (Swift runtime copies, etc.)
if [ -d "${APP}/Contents/Frameworks" ]; then
    echo "==> Signing bundled frameworks & dylibs"
    find "${APP}/Contents/Frameworks" \
        \( -name "*.framework" -o -name "*.dylib" \) \
        -not -path "*Sparkle.framework*" -maxdepth 2 | while read -r item; do
        echo "    codesign ${item}"
        codesign "${CODESIGN_FLAGS[@]}" "${item}"
    done
fi

# Finally the app itself, with entitlements (Hardened Runtime on).
echo "==> Signing app bundle"
codesign "${CODESIGN_FLAGS[@]}" --entitlements "${ENTITLEMENTS}" "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"
echo "codesign-app.sh: done."
