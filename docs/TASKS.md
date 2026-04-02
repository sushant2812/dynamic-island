## Tasks

This file tracks the build of a Dynamic Island–inspired **macOS menu bar app** written in **SwiftUI + AppKit**.

### macOS MVP (v1)

- [ ] **Scaffold app**: Swift Package executable target under `macos/` with AppKit `NSApplication` + SwiftUI content.
- [ ] **Menu bar integration**: `NSStatusItem` with icon, menu (toggle island, quit), accessory-only app (no Dock icon).
- [ ] **Dynamic Island panel**: borderless `NSPanel` pinned top-center, transparent background, collapsed/expanded pill UI, smooth animations.
- [ ] **Now Playing service (Spotify)**:
  - [ ] Poll Spotify via AppleScript for track/artist/state.
  - [ ] Normalize into `AudioSession` model.
  - [ ] Support play/pause when Spotify is active.
- [ ] **Now Playing service (Chrome)**:
  - [ ] Poll active Chrome tab title as fallback when Spotify is idle/absent.
  - [ ] Normalize into `AudioSession` with `source = .chrome`.
- [ ] **Pill UI wiring**:
  - [ ] Bind pill text/icon/dot state to `AudioSession`.
  - [ ] Tap to play/pause Spotify when supported.
  - [ ] Tap/hover to expand panel.
- [ ] **Internal notifications**:
  - [ ] In‑app SwiftUI notification queue with TTL.
  - [ ] Show events like “Now playing…” and “Input switched…”.
- [ ] **macOS input devices (later pass)**:
  - [ ] List input devices via CoreAudio.
  - [ ] Set default input device.
  - [ ] Surface changes in the expanded panel.
- [ ] **Hardening**:
  - [ ] Handle “no session”, Spotify/Chrome not running, AppleScript failures.
  - [ ] Graceful fallbacks in UI (idle state, subtle error messaging).

### Packaging & docs

- [ ] **Packaging**: Xcode project or `xcodebuild` setup for signing/notarizing the menu bar app.
- [ ] **README**: how to run (`swift run` vs built app), permissions needed (Accessibility, Automation), known limitations (Spotify + Chrome only, heuristics).

### Milestones

- **Milestone A (macOS MVP)**: Menu bar app scaffold + island panel + Spotify/Chrome Now Playing + basic notifications.
- **Milestone B (macOS devices)**: CoreAudio input device list/switch + panel UI.
- **Milestone C (ship)**: packaging, notarization plan, polish pass on animations/UX + docs.
# Tasks

This file tracks the build of a Dynamic Island–inspired desktop widget for **macOS + Windows**.

## MVP (v1)

- [ ] **Scaffold app**: Electron + React + TypeScript (main/renderer split, dev/build scripts)
- [ ] **Dynamic Island window**: frameless + transparent + always-on-top, top-center positioning, collapsed/expanded UI, basic animations
- [ ] **IPC contracts**: typed channels for audio session updates, devices list/switch, internal notifications
- [ ] **macOS audio (now playing)**: detect current media session; normalize session model; play/pause when supported
- [ ] **macOS input devices**: list input devices; set default input device; expose via IPC
- [ ] **Notifications (internal)**: renderer queue with TTL + animations; show events like “Now playing…” and “Input switched…”
- [ ] **Tray/menu-bar**: show/hide island, settings, quit
- [ ] **Hardening**: permission + failure states (no session, denied access, helper failure) with clear user feedback

## Windows parity (v1.5)

- [ ] **Windows audio backend**: now playing/session tracking + basic controls (match normalized model)
- [ ] **Windows input devices backend**: list/switch default input device (match normalized model)
- [ ] **Cross-platform pass**: confirm window behavior + z-order, multi-monitor behavior (primary monitor for v1), shortcuts

## Packaging & docs

- [ ] **Packaging**: macOS + Windows installers (and signing/notarization plan if needed later)
- [ ] **README**: install/run steps, permissions notes, known limitations

## Milestones

- **Milestone A (macOS MVP)**: Scaffold + island window + IPC + macOS audio + macOS input switching + internal notifications
- **Milestone B (Windows parity)**: Windows audio + Windows device switching + cross-platform behavior fixes
- **Milestone C (ship)**: packaging + docs

