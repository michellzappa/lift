# Working on Lift

Lift controls a Linak standing desk (IKEA Idasen and others) from the macOS
menu bar over Bluetooth LE. AppKit, Swift 6, macOS 14, bundle id
`app.lift.Lift`.

## Build

XcodeGen owns the project. Edit `project.yml`, then run `xcodegen generate`.
`Lift.xcodeproj` is not in git. Never hand-edit it.

- `./scripts/build-app.sh` regenerates the project and the icon, builds
  Release, signs with the stable Apple Development identity and installs to
  `/Applications/Lift.app`. `--debug` builds Debug. This is for mz's Mac.
- The green gate is the CI build (`.github/workflows/build.yml`):

```bash
xcodegen generate && xcodebuild build -project Lift.xcodeproj -scheme Lift -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

Run it on mz-mini with `remote-build '<command>'` from inside the clone. Do
not build Swift on the laptop.

## Shared package

HouseKit (`michellzappa/housekit`) supplies the menu bar plate, the app icon,
the status menu tail, the settings window, launch at login and the changelog
parser. `project.yml` pins a HouseKit release tag by URL (`exactVersion`), so
CI, mz-mini and the laptop build the same code.

- To change HouseKit: merge in its repo, tag a new release, then move the pin
  here on purpose. Never go back to `path: ../housekit`.
- `scripts/build-app.sh` builds `housekit-icon` from the resolved package
  checkout in `build/DerivedData`. Set `HOUSEKIT_PATH` to try a local
  HouseKit clone.

## Release

`.github/workflows/release.yml` runs on a `v*` tag. The tag must match
`CFBundleShortVersionString` in `Lift/Resources/Info.plist`. The workflow archives a
universal app, signs it with Developer ID, notarizes, staples and publishes a
zip plus `SHA256SUMS` to GitHub Releases.

- Add a `CHANGELOG.md` entry `## X.Y.Z - YYYY-MM-DD` before you tag. The app
  bundles the file for HouseKit's About pane.
- The workflow needs six secrets: `APPLE_TEAM_ID`,
  `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64`, `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY_BASE64`.

## Traps

- This repo has no Actions secrets. Every release run failed, so `v0.1.0`
  is a tag with no GitHub release. Add the secrets before the next tag.
- Sign local builds with the stable Apple Development identity
  (`build-app.sh` does this). TCC keys permission grants to the signature, so
  an ad-hoc build loses them on every rebuild.
- You cannot check desk movement in CI or on mz-mini. mz tests it by hand
  with the desk.
- Settings still uses the deprecated AppKit `SettingsWindowController` and
  `AboutPage`. They do not show the changelog. Move to
  `HouseSettingsWindowController` and `AboutSettingsPane` to get it.

## Writing

Docs, comments and commit messages use Simplified Technical English: active
voice, short sentences, one word for one thing. No em dashes in UI copy.
