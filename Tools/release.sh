#!/bin/sh
# Archives Gauss and uploads it to App Store Connect, for TestFlight.
# The build number is the commit count, so every upload from a new commit
# gets a higher number. Needs a clean, pushed tree, so the About screen's
# commit link works and the build matches the public source.
#
# Xcode's own upload fails when the team name has accents (the signature's
# designated requirement spells é differently from the certificate), so the
# exported app is re-signed with a requirement on the Team ID instead, then
# uploaded with altool. Needs an Apple Distribution certificate in the
# keychain and an App Store Connect API key (see Config/Local.xcconfig.example).
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

setting() { sed -n "s/^$1 *= *//p" Config/Local.xcconfig; }
team=$(setting DEVELOPMENT_TEAM)
key_id=$(setting ASC_KEY_ID)
issuer=$(setting ASC_ISSUER_ID)
if [ -z "$team" ] || [ -z "$key_id" ] || [ -z "$issuer" ]; then
    echo "Set DEVELOPMENT_TEAM, ASC_KEY_ID and ASC_ISSUER_ID in Config/Local.xcconfig." >&2; exit 1
fi
identity=$(security find-identity -v -p codesigning | grep "Apple Distribution: .*($team)" | awk '{print $2; exit}')
if [ -z "$identity" ]; then
    echo "No Apple Distribution certificate for team $team in the keychain." >&2; exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first." >&2; exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Push main to GitHub first." >&2; exit 1
fi

build=$(git rev-list --count HEAD)
archive="build/Gauss-$build.xcarchive"
export="build/export-$build"
echo "Archiving Gauss build $build ($(git rev-parse --short HEAD))…"
xcodebuild -project Gauss.xcodeproj -scheme Gauss -configuration Release \
    -destination generic/platform=iOS -archivePath "$archive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive

echo "Exporting…"
rm -rf "$export"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist Tools/ExportOptions.plist \
    -exportPath "$export" -allowProvisioningUpdates

echo "Re-signing…"
mkdir "$export/ipa"
unzip -q "$export/Gauss.ipa" -d "$export/ipa"
app="$export/ipa/Payload/Gauss.app"
codesign -d --entitlements - --xml "$app" > "$export/entitlements.plist"
codesign -f -s "$identity" --entitlements "$export/entitlements.plist" --generate-entitlement-der \
    -r="designated => anchor apple generic and identifier \"net.lastninja.gauss\" and certificate leaf[subject.OU] = \"$team\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */" \
    "$app"
codesign --verify --deep --strict "$app"
ipa="$PWD/$export/Gauss-$build.ipa"
(cd "$export/ipa" && zip -qry "$ipa" .)

echo "Uploading to App Store Connect…"
xcrun altool --upload-app -f "$ipa" -t ios --api-key "$key_id" --api-issuer "$issuer"
