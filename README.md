# Accio

*Accio* is the Summoning Charm: summon any hidden menu bar item by name.

A lightweight, polished, open-source menu bar manager for macOS. It hides the icons you rarely use,
brings any of them back on demand, and keeps them out from behind the notch.

> **Status:** Phase 2. Hides the menu bar items you choose (Hidden / Always Hidden), brings them back on
> demand, and rearranges the real menu bar from a drag-and-drop layout editor.

## Docs

- [Build plan](docs/PLAN.md): goals, performance budgets, architecture, phases
- [Spike results](docs/spikes.md): what works on macOS 27 and what doesn't

## Build and run

```bash
./scripts/build.sh            # → build/Accio.app
open build/Accio.app
```

- **Click** the wand to show Hidden items, **⌥-click** to show Always Hidden items too,
  **right-click** for the menu.
- **⌃⌥⌘A** shows Hidden items from anywhere; they hide again after 10 s (configurable).
- **Hidden items menu:** if revealed items don't fit next to the notch, Accio lists them in a menu under
  its icon; choose one to open it (hold ⌥ for a secondary click). Settings → General can show hidden
  items in that menu instead of the menu bar, and add two more ways to show them: resting the pointer on
  empty menu bar space, and swiping down on the menu bar (up hides them).
- **Settings → Layout** lists every item in three rows: Shown, Hidden, Always Hidden. Drag an item to
  another row to change when it shows; drop it onto another item to move it next to that item in the real
  menu bar. Needs Accessibility access (the first-launch window asks for it).
- Accio keeps Hidden items to the left of its wand and Shown items to its right, so the wand stays put
  when items show and hide. Moving an item to another row moves it across the wand; **Tidy Up** in
  Layout arranges the whole bar.
- Run `./scripts/dev-signing.sh` once: builds are then signed with a local identity, so macOS keeps the
  Accessibility grant across rebuilds.
- Without an Apple-issued certificate, macOS hides Accio's own status item along with the rest
  ([why](docs/spikes.md#1d-the-allow-list-needs-a-team-signature--found-in-phase-1)), so Accio draws a
  stand-in icon in the menu bar while hiding. It works the same way.

## Spikes

```bash
cd spikes
swift build
.build/debug/spike          # list commands
.build/debug/spike ax       # menu bar items via Accessibility
```

The host terminal needs Accessibility (and, for some spikes, Screen Recording) permission.

## Requirements

macOS 26 or later. Builds with the Xcode Command Line Tools (Swift 6), no Xcode project.

## License

[MIT](LICENSE)
