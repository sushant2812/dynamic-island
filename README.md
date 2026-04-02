# Dynamic Island

Dynamic Island-inspired desktop UI experiments, currently focused on a native macOS menu bar app.

## Current status

- Native macOS app lives in `macos/` (SwiftUI + AppKit, Swift Package).
- It shows a top-center island panel with:
  - now playing metadata (Spotify, Apple Music, supported browsers),
  - media controls (play/pause, next, previous where supported),
  - source switching between active now-playing providers,
  - audio output device switching (default output via CoreAudio).





## Requirements

- macOS 13+
- Xcode command line tools (`xcode-select --install`)
- Accessibility / Automation permissions for AppleScript-driven media controls

## Run (native macOS app)

From repo root:

```bash
cd macos
swift run
```

This launches as an accessory app (no Dock icon) and creates a menu bar item.

## Build

```bash
cd macos
swift build
```

## Usage

- Click the menu bar capsule icon to toggle island visibility.
- Click the collapsed island to expand it when media is available.
- In expanded mode:
  - use transport controls for track playback,
  - switch active media source from source icons,
  - open the speaker menu to change output device.

## Screenshots

![Collapsed island](<assets/screenshots/island-collapsed.png>)
![Expanded island](<assets/screenshots/island-expanded.png>)

## Permissions notes

Because this project uses AppleScript for media app/browser integration, macOS may prompt for Automation permissions (for apps like Spotify, Music, Chrome/Arc/Brave/etc.). Granting those permissions improves reliability of metadata and controls.

## Known limitations

- Browser media detection is heuristic and depends on active tabs/process responsiveness.
- Device switching currently targets **output** devices only.
- Multi-monitor and space behavior is still being iterated.

## Roadmap

- **Milestone A: macOS final polish**
  - Tighten now-playing reliability across Spotify, Music, and browsers
  - Improve island interaction states (eg: prioritizing notifications while audio is playing)
  - Add support for notification events
  - Make a Package release everytime a push occurs (maybe CI/CD pipeline would work here)
- **Milestone B: Device Management**
  - Refine audio device switching UX in the expanded panel
  - Add clearer feedback when a device change succeeds/fails
- **Milestone C: cross-platform parity**
  - Add support for Windows/Linux
  - Align normalized media/device models across platforms
  - Validate window/panel behavior on multi-monitor setups

