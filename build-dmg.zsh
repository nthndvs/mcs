#!/bin/zsh
# Build a self-contained, personal-share DMG for Model Compare Studio.
# This uses ad-hoc signing, so recipients may need to Control-click the app and
# choose Open once. Replace `-` in build-app.zsh's codesign command with a
# Developer ID and notarize the DMG before broad public distribution.

emulate -LR zsh
setopt err_return no_unset pipe_fail

root=${0:A:h}
app="$root/Model Compare Studio.app"
dist="$root/dist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$dist/Model-Compare-Studio-${version}.dmg"

"$root/build-app.zsh"

build_dir=$(mktemp -d "/private/tmp/model-compare-studio-dmg.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$dist"

stage="$build_dir/Model Compare Studio"
mkdir -p "$stage"
ditto "$app" "$stage/Model Compare Studio.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Model Compare Studio" -srcfolder "$stage" -ov -format UDZO "$output"
shasum -a 256 "$output" >"$output.sha256"

print -- "Created: $output"
print -- "Checksum: $output.sha256"
