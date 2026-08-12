#!/bin/zsh
# Compile Model Compare Studio and assemble its .app bundle.
# Uses ad-hoc signing, matching the previous personal-share build.

emulate -LR zsh
setopt err_return no_unset pipe_fail

root=${0:A:h}
app="$root/Model Compare Studio.app"
resources="$app/Contents/Resources"
runner="$root/ask-all.zsh"

sdk=$(xcrun --sdk macosx --show-sdk-path)

# Swift's module cache must stay outside the per-app temporary directory on
# current macOS releases; `/private/tmp` is reliable for Command Line Tools.
build_dir=$(mktemp -d "/private/tmp/model-compare-studio.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

mkdir -p "$app/Contents/MacOS" "$resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"

# Build for Apple Silicon. Add a separately verified x86_64 build before using
# this with Intel Macs. The binary is the bundle's real CFBundleExecutable so
# LaunchServices/Dock treat it as a first-class, pinnable app.
xcrun swiftc -sdk "$sdk" -target arm64-apple-macosx15.5 \
  -module-cache-path "$build_dir/module-cache-arm64" \
  -framework AppKit -framework Security \
  "$root"/Sources/*.swift "$root"/Sources/Views/*.swift \
  -o "$app/Contents/MacOS/Model Compare Studio"
chmod +x "$app/Contents/MacOS/Model Compare Studio"

cp "$runner" "$resources/ask-all.zsh"
chmod +x "$resources/ask-all.zsh"
cp "$root/assets/AppIcon.icns" "$resources/AppIcon.icns"

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

print -- "Built: $app"
