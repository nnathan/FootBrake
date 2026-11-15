#!/bin/sh
# Archives FootBrake and uploads it to App Store Connect, for TestFlight.
# The build number is the commit count, so every upload from a new commit
# gets a higher number. Needs a clean, pushed tree, so the About screen's
# commit link works and the build matches the public source.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first." >&2; exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Push main to GitHub first." >&2; exit 1
fi

build=$(git rev-list --count HEAD)
archive="build/FootBrake-$build.xcarchive"
echo "Archiving FootBrake build $build ($(git rev-parse --short HEAD))…"
xcodebuild -project FootBrake.xcodeproj -scheme FootBrake -configuration Release \
    -destination generic/platform=iOS -archivePath "$archive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist Tools/ExportOptions.plist \
    -exportPath "build/export-$build" -allowProvisioningUpdates
