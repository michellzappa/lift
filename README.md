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

Needs `xcodegen`. [HouseKit](https://github.com/michellzappa/housekit), pinned to a
release tag in `project.yml`,
supplies the menu bar plate, the app icon, the settings window chrome, the
shortcut recorder and launch-at-login — the pieces Lift shares with Tessellate,
Cargo and Clip. To work in Xcode instead: `xcodegen generate && open Lift.xcodeproj`.

Signing uses the stable Apple Development identity from `project.yml`; set your
own `DEVELOPMENT_TEAM` first. The Bluetooth grant is keyed to the signature.

## Configuration

Settings lives in the menu bar item (⌘,): **Desk** (connection, presets in cm,
hotkeys) · **History** (local sitting/standing history for the last 24 hours,
7 days, 30 days, or 90 days) · **General** (launch at login, menu bar icon,
Bluetooth status) · **About**.

## Architecture

AppKit throughout, no dependencies beyond `HouseKit`.

| | |
| --- | --- |
| `Desk/DeskController` | CoreBluetooth central: discovery, reconnect on sleep/wake, height notifications, move-to loop, nudge, stop |
| `Models/LiftSettings` | Presets, hotkeys, remembered desk; `UserDefaults` |
| `History/PresenceMonitor` | At-this-Mac detection: local input in the last 5 min, screen awake and unlocked, no Screen Sharing session (`screensharingd` running) |
| `History/HistoryStore` | Local sit/stand/away transitions, summaries, and day/week/month aggregation; sitting and standing count only while present |
| `History/HistoryPage` | The 24h/7d/30d/90d history view and chart |
| `Settings/DeskPage` | Lift's Desk and History pages in the HouseKit settings window, next to the shared General and About pages |
| `App/LiftApp` | `NSStatusItem` and its menu — height header, Sit/Stand with shortcuts, nudge, save-as, then the house tail |

Protocol details come from the open `idasen` and `linak-controller` projects.

## Limitations

- One desk. Forget it in Settings to pair another.
- No collision detection beyond the desk's own; Stop is a menu click or ⌘. away.
- Height range is hard-coded to the Idasen's 62–127 cm.
