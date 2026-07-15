#!/usr/bin/env bash
# ============================================================
# create-dmg.sh — Build a DMG installer for Spacie
# Requires: create-dmg (brew install create-dmg)
# Usage: ./scripts/create-dmg.sh <app-bundle> <output-dmg> <version>
# ============================================================

set -euo pipefail

APP_BUNDLE="${1:?Usage: create-dmg.sh <app-bundle-path> <output-dmg-path> <version>}"
DMG_OUTPUT="${2:?Usage: create-dmg.sh <app-bundle-path> <output-dmg-path> <version>}"
VERSION="${3:?Usage: create-dmg.sh <app-bundle-path> <output-dmg-path> <version>}"

APP_NAME="Spacie"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "Error: App bundle not found at ${APP_BUNDLE}" >&2
    exit 1
fi

if ! command -v create-dmg &> /dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

rm -f "${DMG_OUTPUT}"
mkdir -p "$(dirname "${DMG_OUTPUT}")"

echo "Creating DMG for ${APP_NAME} v${VERSION}..."

# create-dmg returns exit code 2 if it cannot set custom icon (non-fatal).
set +e
VOLICON=""
if [ -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]; then
    VOLICON="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    ${VOLICON:+--volicon "${VOLICON}"} \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 150 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 450 190 \
    --no-internet-enable \
    "${DMG_OUTPUT}" \
    "${APP_BUNDLE}"

EXIT_CODE=$?
set -e

# Exit code 2 = icon customization issue (non-fatal, DMG is still valid)
if [ "${EXIT_CODE}" -ne 0 ] && [ "${EXIT_CODE}" -ne 2 ]; then
    echo "Error: create-dmg failed with exit code ${EXIT_CODE}" >&2
    exit "${EXIT_CODE}"
fi

if [ ! -f "${DMG_OUTPUT}" ]; then
    echo "Error: DMG was not created at ${DMG_OUTPUT}" >&2
    exit 1
fi

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1)
echo "DMG created successfully: ${DMG_OUTPUT} (${DMG_SIZE})"
