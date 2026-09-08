#!/usr/bin/env bash
# Builds and signs OrganizeDownloads.app.
#
# The bundle identifier and the stable signing identity are the whole point of
# this build: TCC keys its grants to them, so Full Disk Access survives every
# rebuild instead of being reset by each new ad-hoc signature.
set -euo pipefail

BUNDLE_ID="local.organize-downloads"
APP_NAME="OrganizeDownloads"
SIGN_IDENTITY="${SIGN_IDENTITY:-Downloads Organizer Local Signing}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/build}"
app="$out/$APP_NAME.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>Organize Downloads</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>3.1.0</string>
	<key>CFBundleVersion</key>
	<string>4</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

echo "compiling..."
# -Osize over -O: this is an idle daemon, so a smaller text segment (fewer
# pages faulted in and kept resident) is worth more than inlining.
# -dead_strip drops anything the linker can prove is unreachable.
swiftc -Osize -swift-version 5 \
	-Xlinker -dead_strip \
	-o "$app/Contents/MacOS/$APP_NAME" \
	"$here/Sources/Posix.swift" \
	"$here/Sources/Config.swift" \
	"$here/Sources/Log.swift" \
	"$here/Sources/DirectoryPoller.swift" \
	"$here/Sources/WorkerRunner.swift" \
	"$here/Sources/main.swift"

echo "signing as: $SIGN_IDENTITY"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$app"
codesign --verify --strict --verbose=2 "$app"

echo "built: $app"
