# Changelog

Every entry below is a `v`-prefixed git tag. Add an entry here before you cut
a tag. The app bundles this file for HouseKit (`Changelog.load`).

## Unreleased

- MIT license.
- Posture history: sitting and standing count only while you are at this
  Mac. Screen Sharing sessions count as away. Day, week and month graphs,
  standing share, and the last 24 hours in the menu.
- A height counts as the nearest preset, so a desk a few centimetres short
  of Stand still counts as standing.
- The taller preset is first in the menu.
- Menu bar and app icon: three desk heights (HouseKit 0.2.1).

## 0.1.0 - 2026-09-14

- First release. Lift controls a Linak standing desk (IKEA Idasen and
  others) from the menu bar over Bluetooth LE.
- Sit and Stand presets with global hotkeys, nudge up and down, and the
  current height in the menu.
- `lift://sit`, `lift://stand`, `lift://toggle` and `lift://settings` URLs.
- Settings: the preset fields show their values the first time the window
  opens.
