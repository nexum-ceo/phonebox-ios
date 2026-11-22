#!/usr/bin/env bash
# Builds "PhoneBox Starter.app" (menu bar app that starts and stops the PhoneBox agent) without an Xcode project.
#   ./build.sh            build into mac-starter/build/
#   ./build.sh --install  also copy it to ~/Applications and open it
set -euo pipefail
cd "$(dirname "$0")"

app="build/PhoneBox Starter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"

# one binary for Apple silicon and Intel
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    PhoneBoxStarter.swift -o "build/PhoneBoxStarter-$arch"
done
lipo -create build/PhoneBoxStarter-arm64 build/PhoneBoxStarter-x86_64 -output "$app/Contents/MacOS/PhoneBoxStarter"
rm build/PhoneBoxStarter-arm64 build/PhoneBoxStarter-x86_64

# icon: the phone app's icon
icon=../PhoneBox/Assets.xcassets/AppIcon.appiconset/icon.png
if [ -f "$icon" ]; then
  set_dir="build/AppIcon.iconset"
  rm -rf "$set_dir"; mkdir -p "$set_dir"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$icon" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$icon" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$set_dir"
fi

codesign --force --sign - "$app" >/dev/null
echo "built: mac-starter/$app"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/PhoneBox Starter.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/PhoneBox Starter.app"
  echo "installed: ~/Applications/PhoneBox Starter.app"
fi
