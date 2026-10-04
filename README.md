# Accio

*Accio* is the Summoning Charm: summon any hidden menu bar item by name.

A lightweight, polished, open-source menu bar manager for macOS. It hides the icons you rarely use,
brings any of them back on demand, and keeps them out from behind the notch.

> **Status:** Phase 1, MVP. Hides the menu bar apps you choose and brings them back on demand.

## Docs

- [Build plan](docs/PLAN.md): goals, performance budgets, architecture, phases
- [Spike results](docs/spikes.md): what works on macOS 27 and what doesn't

## Build and run

```bash
./scripts/build.sh            # → build/Accio.app
open build/Accio.app
```

- **Click** the wand to show or hide items, **right-click** it for the menu, **⌥-click** for Settings.
- **⌃⌥⌘A** shows hidden items from anywhere; they hide again after 10 s (configurable).
- Choose what's hidden in **Settings → Menu Bar Items**. Listing apps needs Accessibility access.
- Ad-hoc builds hide their own icon too ([why](docs/spikes.md#1d-the-allow-list-needs-a-team-signature--found-in-phase-1)).
  Set `ACCIO_SIGN_IDENTITY` to a signing identity to avoid that, and to keep the Accessibility grant
  across rebuilds.

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
