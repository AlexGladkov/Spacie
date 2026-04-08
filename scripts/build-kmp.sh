#!/bin/bash
# Build KMP SpacieKit XCFramework
# Usage: ./scripts/build-kmp.sh [Debug|Release]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SHARED_DIR="$PROJECT_ROOT/shared"

CONFIG="${CONFIGURATION:-${1:-Debug}}"

if [ "$CONFIG" = "Debug" ]; then
    GRADLE_TASK="assembleSpacieKitDebugXCFramework"
    GRADLE_CONFIG="debug"
else
    GRADLE_TASK="assembleSpacieKitReleaseXCFramework"
    GRADLE_CONFIG="release"
fi

# Resolve JDK — prefer 21, fallback to 17, accept system default
if /usr/libexec/java_home -v 21 &>/dev/null; then
    export JAVA_HOME=$(/usr/libexec/java_home -v 21)
elif /usr/libexec/java_home -v 17 &>/dev/null; then
    export JAVA_HOME=$(/usr/libexec/java_home -v 17)
fi

echo "[SpacieKit] Config: $CONFIG"
echo "[SpacieKit] Task: $GRADLE_TASK"
echo "[SpacieKit] JAVA_HOME: ${JAVA_HOME:-system default}"

cd "$SHARED_DIR"
./gradlew "$GRADLE_TASK" --no-daemon -q

XCFW_PATH="$SHARED_DIR/build/XCFrameworks/$GRADLE_CONFIG/SpacieKit.xcframework"
if [ -d "$XCFW_PATH" ]; then
    echo "[SpacieKit] ✓ XCFramework ready: $XCFW_PATH"
else
    echo "[SpacieKit] ✗ ERROR: XCFramework not found at $XCFW_PATH" >&2
    exit 1
fi
