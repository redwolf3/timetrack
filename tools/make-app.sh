#!/usr/bin/env bash
#
# make-app.sh — assemble a real macOS .app bundle around the SwiftPM executable.
#
# `swift build` only emits a bare `TimeTrackApp` Mach-O — no Info.plist, no
# bundle. A bare executable has NO bundle identifier, which silently disables
# UNUserNotifications (AppState guards on `Bundle.main.bundleIdentifier != nil`)
# and blocks SMAppService launch-at-login (#21). This script wraps the binary in
# a minimal, ad-hoc-signed .app so those code paths activate and the README
# install steps actually work.
#
# Usage:
#   ./tools/make-app.sh            # build release + assemble .build/bundle/TimeTrack.app
#   ./tools/make-app.sh install    # also copy it into /Applications (replacing any prior copy)
#
# Env overrides:
#   VERSION   short version string (CFBundleShortVersionString)   default: 0.1.0
#   BUILD     build number          (CFBundleVersion)             default: 1
#
set -euo pipefail

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# --- Bundle metadata ---------------------------------------------------------
APP_NAME="TimeTrack"                       # user-facing name + .app / menu name
BUNDLE_ID="com.redwolf3.timetrack"         # reverse-DNS; identity for notification perms
PRODUCT="TimeTrackApp"                     # SwiftPM executable product name
MIN_MACOS="14.0"                           # matches Package.swift platforms
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

OUT_DIR="${ROOT}/.build/bundle"            # under .build/ — already gitignored
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

# --- Build the release binary ------------------------------------------------
echo "▸ swift build -c release --product ${PRODUCT}"
swift build -c release --product "${PRODUCT}"
BIN="$(swift build -c release --product "${PRODUCT}" --show-bin-path)/${PRODUCT}"
[ -f "${BIN}" ] || { echo "error: built binary not found at ${BIN}" >&2; exit 1; }

# --- Assemble the bundle (clean slate each run) ------------------------------
echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS"

# CFBundleExecutable is "TimeTrack" (clean menu name), so copy the binary under
# that name rather than the SwiftPM product name.
cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"
chmod +x "${CONTENTS}/MacOS/${APP_NAME}"

# Classic 8-byte type/creator file. Harmless, expected by some tooling.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Info.plist. LSUIElement=true → menu-bar agent, no Dock icon / no app menu,
# which is the whole design (DESIGN.md: menu-bar-only). Generated inline so the
# version is the single source and there is no separate template to drift.
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>TimeTrack</string>
</dict>
</plist>
PLIST

# Validate the plist before signing — fail loudly on a malformed bundle.
plutil -lint "${CONTENTS}/Info.plist" >/dev/null

# --- Ad-hoc code signature ---------------------------------------------------
# Local-use signing. An ad-hoc signature gives the bundle a stable identity on
# THIS machine so macOS persists the notification authorization across launches.
# Not for distribution (no Developer ID / notarization — out of scope for v0.1).
echo "▸ codesign (ad-hoc)"
codesign --force --sign - "${APP}"
codesign --verify --strict "${APP}"

echo "✓ built ${APP}  (v${VERSION} build ${BUILD}, id ${BUNDLE_ID})"

# --- Optional install --------------------------------------------------------
if [ "${1:-}" = "install" ]; then
	DEST_DIR="/Applications"
	DEST="${DEST_DIR}/${APP_NAME}.app"
	# /Applications is writable by admin users on a default macOS setup, but not
	# on a managed/non-admin Mac. Elevate ONLY the file ops in that case — the
	# build already ran as the invoking user, so .build stays user-owned and we
	# never run `swift build` as root. If sudo is unavailable/denied it fails with
	# its own clear message rather than a terse set -e abort from rm/cp.
	SUDO=""
	if [ ! -w "${DEST_DIR}" ]; then
		echo "▸ ${DEST_DIR} is not writable by $(whoami) — using sudo for the install copy"
		SUDO="sudo"
	fi
	echo "▸ installing to ${DEST}"
	${SUDO} rm -rf "${DEST}"
	${SUDO} cp -R "${APP}" "${DEST}"
	echo "✓ installed ${DEST}"
fi
