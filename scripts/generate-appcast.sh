#!/usr/bin/env bash
# ============================================================
# generate-appcast.sh — Produce appcast.xml for Sparkle
#
# Wraps Sparkle's `generate_appcast`. Signs each DMG in the
# archives dir with the EdDSA private key and writes appcast.xml
# with enclosure URLs pointing at the GitHub Releases download.
#
# The private key comes from either:
#   - the login Keychain, account "Spacie" (local, default), or
#   - SPARKLE_ED_PRIVATE_KEY env var (CI) — written to a temp file
#     and passed via --ed-key-file.
#
# Usage:
#   ./scripts/generate-appcast.sh <archives-dir> <download-url-prefix>
#
# Example (CI):
#   ./scripts/generate-appcast.sh dist \
#     "https://github.com/AlexGladkov/Spacie/releases/download/v1.4.0/"
# ============================================================

set -euo pipefail

ARCHIVES_DIR="${1:?Usage: generate-appcast.sh <archives-dir> <download-url-prefix>}"
DOWNLOAD_PREFIX="${2:?Usage: generate-appcast.sh <archives-dir> <download-url-prefix>}"

# Keychain account holding Spacie's EdDSA private key (see scripts/README or docs).
SPARKLE_ACCOUNT="Spacie"

# Locate generate_appcast in the resolved SPM artifacts. Search only dirs that
# exist and stop at the first match — avoids `set -e` tripping on a missing
# search root, and avoids the `find | head` SIGPIPE that pipefail turns fatal.
GEN=""
for root in build/DerivedData "${HOME}/Library/Developer/Xcode/DerivedData"; do
    [ -d "${root}" ] || continue
    found=$(find "${root}" -type f -name generate_appcast -path "*parkle*" -print -quit 2>/dev/null || true)
    if [ -n "${found}" ]; then
        GEN="${found}"
        break
    fi
done

if [ -z "${GEN}" ]; then
    echo "Error: generate_appcast not found. Resolve SPM packages first" >&2
    echo "       (xcodebuild -resolvePackageDependencies -scheme Spacie)." >&2
    exit 1
fi

echo "==> Using ${GEN}"

# CI passes the private key via env; locally we read it from the keychain account.
KEY_ARGS=()
CLEANUP_KEY=""
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    CLEANUP_KEY="$(mktemp)"
    printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" > "${CLEANUP_KEY}"
    KEY_ARGS=(--ed-key-file "${CLEANUP_KEY}")
    trap 'rm -f "${CLEANUP_KEY}"' EXIT
else
    KEY_ARGS=(--account "${SPARKLE_ACCOUNT}")
fi

"${GEN}" \
    "${KEY_ARGS[@]}" \
    --download-url-prefix "${DOWNLOAD_PREFIX}" \
    "${ARCHIVES_DIR}"

echo "==> appcast written to ${ARCHIVES_DIR}/appcast.xml"
