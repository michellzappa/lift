# Lift

A minimal native macOS menu-bar controller for a Linak-based standing desk
(IKEA Idasen and friends). Two presets, two hotkeys, the height in the menu.

The product principle: **hotkey → desk moves.** Sit and Stand are the whole
job; everything else (nudging, saving the current height as a preset) is there
so you never open the app's settings on purpose.

## How it works

Lift connects over Bluetooth LE to the first Linak desk it finds and remembers
it. The menu bar item shows the current height and posture; ⌃⌥↓ sits, ⌃⌥↑
stands (rebindable). "Save Current as Sit/Stand Height" turns wherever the
desk is right now into the preset.

Moving writes the target to the desk's reference-input characteristic until
the height reading is within 3 mm, then sends stop. Nudge Up/Down pulse the
control characteristic for 400 ms. Stop is ⌘. in the menu.

`lift://sit`, `lift://stand`, `lift://toggle` and `lift://settings` do the
same from Shortcuts, Raycast, or a keyboard macro.

## Requirements

- macOS 14 (Sonoma) or later
- Bluetooth permission (asked on first launch)
- A desk with a Linak DPG Bluetooth controller: IKEA Idasen, or any desk that
  advertises the `99FA0001-…` control service

## Install

No notarized release yet. Build it yourself:

```sh
./scripts/build-app.sh      # → /Applications/Lift.app, signed, icon regenerated
```

Needs `xcodegen` and the sibling [`../housekit`](../housekit) package, which
supplies the menu bar plate, the app icon, the settings window chrome, the
shortcut recorder and launch-at-login — the pieces Lift shares with Tessellate,
Cargo and Clip. To work in Xcode instead: `xcodegen generate && open Lift.xcodeproj`.

Signing uses the stable Apple Development identity from `project.yml`; set your
own `DEVELOPMENT_TEAM` first. The Bluetooth grant is keyed to the signature.

## Configuration

Settings lives in the menu bar item (⌘,): **Desk** (connection, presets in cm,
hotkeys) · **General** (launch at login, menu bar icon, Bluetooth status) · **About**.

## Architecture

AppKit throughout, no dependencies beyond `HouseKit`.

| | |
| --- | --- |
| `Desk/DeskController` | CoreBluetooth central: discovery, reconnect on sleep/wake, height notifications, move-to loop, nudge, stop |
| `Models/LiftSettings` | Presets, hotkeys, remembered desk; `UserDefaults` |
| `Settings/DeskPage` | Lift's page in the HouseKit settings window, next to the shared General and About pages |
| `App/LiftApp` | `NSStatusItem` and its menu — height header, Sit/Stand with shortcuts, nudge, save-as, then the house tail |

Protocol details come from the open `idasen` and `linak-controller` projects.

## Limitations

- One desk. Forget it in Settings to pair another.
- No collision detection beyond the desk's own; Stop is a menu click or ⌘. away.
- Height range is hard-coded to the Idasen's 62–127 cm.
