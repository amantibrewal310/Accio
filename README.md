# Accio

*Accio* is the Summoning Charm: summon any hidden menu bar item by name.

A lightweight, polished, open-source menu bar manager for macOS. It hides the icons you rarely use,
brings any of them back on demand, and keeps them out from behind the notch.

> **Status:** Phase 0, feasibility spikes. Nothing to install yet.

## Docs

- [Build plan](docs/PLAN.md): goals, performance budgets, architecture, phases
- [Spike results](docs/spikes.md): what works on macOS 27 and what doesn't

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
