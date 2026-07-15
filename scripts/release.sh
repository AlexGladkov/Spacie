#!/usr/bin/env bash
# ============================================================
# release.sh — Full local release pipeline for Spacie
#
# Steps: regenerate project → archive (unsigned) → export .app →
# Developer ID sign (Sparkle-aware) → DMG → notarize+staple →
# generate Sparkle appcast.
#
# Notarization is skipped (with a warning) if no notary credentials
# are present in the environment — the DMG is still Developer-ID signed.
#
# Usage:
#   ./scripts/release.sh [version]
# Version defaults to MARKETING_VERSION from project.yml.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT}"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alex Gladkov (7N3PU42797)}"
ENTITLEMENTS="Spacie/Spacie.entitlements"
BUILD_DIR="${ROOT}/build"
ARCHIVE="${BUILD_DIR}/Spacie.xcarchive"
EXPORT_APP="${BUILD_DIR}/export/Spacie.app"

VERSION="${1:-$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')}"
DMG="${BUILD_DIR}/Spacie-${VERSION}-arm64.dmg"
REPO="${DOWNLOAD_REPO:-AlexGladkov/Spacie}"

echo "=== Spacie Release ${VERSION} ==="

echo "[1/7] Regenerating project (xcodegen)…"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null || echo "  (xcodegen not found, using existing project)"

echo "[2/7] Archiving (unsigned; signed explicitly in step 4)…"
xcodebuild archive \
    -project Spacie.xcodeproj \
    -scheme Spacie \
    -configuration Release \
    -archivePath "${ARCHIVE}" \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    | tail -1

echo "[3/7] Exporting .app…"
mkdir -p "$(dirname "${EXPORT_APP}")"
rm -rf "${EXPORT_APP}"
cp -R "${ARCHIVE}/Products/Applications/Spacie.app" "${EXPORT_APP}"

echo "[4/7] Developer ID signing (Sparkle-aware)…"
"${SCRIPT_DIR}/codesign-app.sh" "${EXPORT_APP}" "${SIGN_IDENTITY}" "${ENTITLEMENTS}"

echo "[5/7] Creating DMG…"
"${SCRIPT_DIR}/create-dmg.sh" "${EXPORT_APP}" "${DMG}" "${VERSION}"

echo "[6/7] Notarizing…"
if [ -n "${NOTARY_API_KEY_PATH:-}${NOTARY_PROFILE:-}${NOTARIZE_APPLE_ID:-}" ]; then
    "${SCRIPT_DIR}/notarize.sh" "${DMG}"
else
    echo "  ⚠️  No notary credentials in env — skipping notarization."
    echo "     DMG is Developer-ID signed but NOT notarized (Gatekeeper will warn)."
fi

echo "[7/7] Generating Sparkle appcast…"
mkdir -p dist
cp "${DMG}" dist/
"${SCRIPT_DIR}/generate-appcast.sh" dist \
    "https://github.com/${REPO}/releases/download/v${VERSION}/"

echo ""
echo "=== Done ==="
echo "DMG:     ${DMG}"
echo "Appcast: ${ROOT}/dist/appcast.xml"
