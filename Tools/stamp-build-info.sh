#!/bin/sh
# Xcode build phase: records the git commit the app was built from in
# BuildInfo.plist inside the app bundle, for the About screen.
# Builds outside a git checkout get "unknown" rather than failing.
set -u

out="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildInfo.plist"
commit=$(git -C "${SRCROOT}" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [ "$commit" != unknown ] && [ -n "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then
    dirty=true
fi

mkdir -p "$(dirname "$out")"
cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Commit</key>
	<string>${commit}</string>
	<key>Dirty</key>
	<${dirty}/>
</dict>
</plist>
PLIST
