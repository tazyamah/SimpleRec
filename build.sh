#!/bin/bash
#
# SimpleRec build script
# Builds with Xcode's toolchain, stamps a build version, deploys a SINGLE
# canonical app to /Applications/SimpleRec.app (replacing any old copy), signs
# it, and launches THAT copy. This avoids stale duplicates and "old version
# keeps launching" problems.
#
set -euo pipefail

APP_NAME="SimpleRec"
APP_DIR="${APP_NAME}.app"
DEST="/Applications/${APP_DIR}"
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"

if [[ -x "${XCODE_DEV}/usr/bin/swift" ]]; then
    export DEVELOPER_DIR="${XCODE_DEV}"
    unset TOOLCHAINS 2>/dev/null || true
    unset SDKROOT 2>/dev/null || true
    SWIFT="${XCODE_DEV}/usr/bin/swift"
else
    SWIFT="swift"
fi

echo "==> Toolchain: $("${SWIFT}" --version | head -1)"

echo "==> Building ${APP_NAME} ..."
"${SWIFT}" build -c release
BIN_PATH="$("${SWIFT}" build -c release --show-bin-path)/${APP_NAME}"
[[ -f "${BIN_PATH}" ]] || { echo "Build failed: binary not found" >&2; exit 1; }

# Assemble bundle in the working dir
echo "==> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
[[ -f "Resources/AppIcon.icns" ]] && cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Stamp a build version so the running app shows which build it is.
BUILD_ID="$(date +%Y%m%d.%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_ID}" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
echo "   build id: ${BUILD_ID}"

# Code sign — prefer stable self-signed identity, else ad-hoc.
echo "==> Code signing ..."
IDENTITY="SimpleRec Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "   using stable identity: ${IDENTITY}"
    codesign --force --deep --sign "${IDENTITY}" "${APP_DIR}"
else
    echo "   using ad-hoc signature."
    echo "   TIP: create a code-signing cert named '${IDENTITY}' (see README) to keep permissions across builds."
    codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
fi

# Deploy the SINGLE canonical copy to /Applications, replacing any old one.
echo "==> Deploying to ${DEST} ..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1
rm -rf "${DEST}"
cp -R "${APP_DIR}" "${DEST}"

echo ""
echo "Done. Canonical app: ${DEST} (build ${BUILD_ID})"
echo ""

# Launch the deployed copy by explicit path (never bundle-id / "reopen").
open "${DEST}"
