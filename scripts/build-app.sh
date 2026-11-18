#!/bin/zsh
# Build Lift.app and install it to /Applications, signed with the stable
# Apple Development identity from project.yml (so the Accessibility grant
# survives rebuilds). Regenerates the Xcode project and the icon every time.
#
#   ./scripts/build-app.sh            # Release → /Applications/Lift.app
#   ./scripts/build-app.sh --debug
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
config=Release
[[ "${1:-}" == "--debug" ]] && config=Debug

cd "$here"
xcodegen generate --quiet
# HouseKit is the tag pinned in project.yml. Resolve it, then build
# housekit-icon from that same checkout. HOUSEKIT_PATH overrides it.
xcodebuild -resolvePackageDependencies -project Lift.xcodeproj -scheme Lift -derivedDataPath build/DerivedData -quiet >/dev/null
housekit="${HOUSEKIT_PATH:-$here/build/DerivedData/SourcePackages/checkouts/housekit}"
# Xcode keeps the package checkout read-only, so build outside it.
scratch="$here/build/housekit-icon"
swift build -c release --package-path "$housekit" --scratch-path "$scratch" >/dev/null
"$(swift build -c release --package-path "$housekit" --scratch-path "$scratch" --show-bin-path)/housekit-icon" lift "$here/Lift/Resources/AppIcon.icns" >/dev/null

build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project Lift.xcodeproj -scheme Lift -configuration "$config" \
  -derivedDataPath build/DerivedData CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGNING_ALLOWED=NO -quiet build
app="build/DerivedData/Build/Products/$config/Lift.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
# Sparkle ships signed by its own team; hardened runtime refuses to load
# a framework from another team, so sign it with ours first.
codesign --force --deep --options runtime --sign "Apple Development" "$app/Contents/Frameworks/Sparkle.framework"
# Xcode's Debug configuration puts the executable code in a nested debug
# dylib. Sign it before signing the app bundle, otherwise macOS library
# validation rejects the installed Debug app at launch.
if [[ -f "$app/Contents/MacOS/Lift.debug.dylib" ]]; then
  codesign --force --sign "Apple Development" --options runtime "$app/Contents/MacOS/Lift.debug.dylib"
fi
codesign --force --sign "Apple Development" --entitlements Lift/Resources/Lift.entitlements --options runtime "$app"

target=/Applications/Lift.app
if pgrep -xq Lift; then osascript -e 'tell application "Lift" to quit' >/dev/null 2>&1 || true; sleep 0.5; fi
rm -rf "$target"
/usr/bin/ditto "$app" "$target"
codesign --verify --strict "$target"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
printf '%s (version %s, build %s)\n' "$target" "$version" "$build"
