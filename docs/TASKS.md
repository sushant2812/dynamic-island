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

