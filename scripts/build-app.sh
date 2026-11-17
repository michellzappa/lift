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
swift build -c release --package-path "$housekit" >/dev/null
"$(swift build -c release --package-path "$housekit" --show-bin-path)/housekit-icon" lift "$here/Lift/Resources/AppIcon.icns" >/dev/null

build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project Lift.xcodeproj -scheme Lift -configuration "$config" \
  -derivedDataPath build/DerivedData CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGNING_ALLOWED=NO -quiet build
app="build/DerivedData/Build/Products/$config/Lift.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
codesign --force --sign "Apple Development" --entitlements Lift/Resources/Lift.entitlements --options runtime "$app"

target=/Applications/Lift.app
if pgrep -xq Lift; then osascript -e 'tell application "Lift" to quit' >/dev/null 2>&1 || true; sleep 0.5; fi
rm -rf "$target"
/usr/bin/ditto "$app" "$target"
codesign --verify --strict "$target"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
printf '%s (version %s, build %s)\n' "$target" "$version" "$build"
