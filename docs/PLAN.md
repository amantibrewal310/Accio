# Build Plan: A Lightweight, Polished Menu Bar Manager for macOS

Name: **Accio**, the Summoning Charm: summon any hidden menu bar item by name.

---

## 1. Goals

- **Performant.** Event-driven, near-zero idle cost, nothing polls unless a feature that needs it is enabled.
- **Lightweight.** Small binary, small memory footprint, no Electron, no heavy dependencies.
- **Polished.** Native look and feel, smooth animations, correct on notch / multi-display / full-screen / Spaces.
- **Private by default.** Fully usable without Screen Recording; that permission only unlocks image-based features.

### Non-goals (v1)
- App Store distribution (private APIs and no sandbox make it impossible).
- Supporting macOS versions older than 26.
- Notch widget hub ("Top Shelf"), clipboard manager, no-code widget builder. Revisit after 1.0.

### Performance budgets (enforced in CI / release checklist)

| Metric | Budget |
|---|---|
| Idle CPU (no reveal, no "show for updates") | < 0.1% averaged over 60 s |
| Idle memory (RSS) | < 35 MB |
| App bundle size | < 10 MB |
| Cold launch to functional | < 300 ms |
| Reveal / hide latency (input → first frame) | < 16 ms (one frame at 60 Hz) |
| Bar dropdown open (with icon images) | < 100 ms |
| Energy Impact in Activity Monitor at idle | "Low" / 0.0 |

---

## 2. Key decisions

| Decision | Choice | Why |
|---|---|---|
| Language | Swift 6, strict concurrency | Native, fast, safe. |
| UI: hot paths (status items, dividers, Bar panel, overlays) | **AppKit** | Precise control over windows, levels and animation; lower overhead than SwiftUI for many small views. |
| UI: Settings, onboarding, layout editor | **SwiftUI** hosted in AppKit windows | Faster to build, looks native. |
| Minimum macOS | **26** | Fewer code paths; the menu bar internals changed in 26, so supporting older versions means maintaining two backends. |
| Dependencies | `KeyboardShortcuts` (hotkeys), `Sparkle` (updates). Nothing else. | Keep the binary small and the supply chain short. |
| Persistence | Single JSON file in Application Support, `Codable` | Easy to inspect, back up and sync; no Core Data. |
| Project | Xcode project + local Swift packages per module | Fast incremental builds, testable modules. |
| Distribution | Developer ID + notarization, DMG + Homebrew cask, Sparkle updates | Standard for non-App-Store Mac apps. Needs the $99/yr Apple Developer account. |
| License | **MIT** | Permissive. We write our own code; Ice (GPL-3.0) is a reference for approach only, never copied. |

---

## 3. Architecture

```
Accio.app
├── App                 // entry point, lifecycle, LSUIElement agent, wiring
├── Core
│   ├── ItemRegistry    // source of truth: every menu bar item, its owner, section, frame
│   ├── ItemDiscovery   // enumerates other apps' status item windows (CGWindowList + private CGS)
│   ├── SectionManager  // divider status items: Shown / Hidden / Always Hidden
│   ├── ItemMover       // reorders items by synthesising ⌘-drag CGEvents
│   ├── ClickForwarder  // brings an item on-screen, sends a synthetic click, restores
│   ├── ImageCapture    // ScreenCaptureKit snapshots of item windows (optional permission)
│   └── Permissions     // Accessibility / Screen Recording state + prompts
├── Features
│   ├── Reveal          // click / hover / scroll / swipe / hotkey triggers, auto-rehide
│   ├── BarPanel        // the dropdown "Bar" below the menu bar
│   ├── Groups          // one status item that opens a mini panel of member items
│   ├── Search          // Spotlight-style panel to find and open any item
│   ├── UpdateWatcher   // "show for updates": change detection on hidden items
│   ├── Profiles        // saved layouts
│   ├── Triggers        // battery, Wi-Fi, app focus, Focus mode, mic/camera, time, script
│   ├── Appearance      // menu bar tint/shape overlay, spacing, spacers
│   └── Automation      // App Intents (Shortcuts/Siri), URL scheme, AppleScript
└── UI
    ├── Settings        // SwiftUI
    ├── LayoutEditor    // drag-and-drop arrangement of items across sections
    └── Onboarding      // permission walkthrough
```

Rules:
- `ItemRegistry` is the only mutable source of truth. Features observe it; they never query the window server directly.
- Everything that touches the window server is behind a protocol (`WindowServerClient`) so it can be faked in tests and swapped if Apple changes internals again.
- Main-actor for UI; window server queries and image diffing run on background actors.

### Performance techniques
- **No timers at idle.** Re-scan items only on: app launch/terminate (`NSWorkspace` notifications), display change, Space change, wake, and an explicit "status items changed" signal. Debounce bursts (e.g. login) to one scan.
- **Hover detection without a global mouse-move firehose:** use a thin transparent tracking window over the empty menu bar region (`NSTrackingArea`), not `addGlobalMonitorForEvents(.mouseMoved)`.
- **Images captured lazily,** only when the Bar / a group / search is opened, and cached until the item changes. Downscale to the menu bar's point size.
- **UpdateWatcher is opt-in per item.** When enabled: capture only watched items, at a low rate (e.g. 1 Hz), compare a 64-bit perceptual hash, stop entirely while the screen is locked or asleep.
- **Animations** via Core Animation on layer-backed views; no per-frame Swift work.
- Profile with Instruments (Time Profiler, Allocations, Energy Log) and `os_signpost` around scan, capture, reveal.

---

## 4. Phases

Estimates assume one experienced developer working part-time-ish. Each phase ends with something usable.

### Phase 0 — Feasibility spikes on macOS 27 (1 week) ⚠️ do this first
macOS internals here are undocumented and changed in 26. Before writing the real app, prove each low-level primitive in a throwaway project:

1. **Divider hiding:** an `NSStatusItem` with a huge length pushes items to its left off-screen, and shrinking it brings them back.
2. **Enumeration:** list every status item window with owner PID / bundle ID and frame. Check which info needs Screen Recording and which doesn't.
3. **Image capture:** grab one item's image via ScreenCaptureKit; measure latency and memory.
4. **Click forwarding:** programmatically open another app's menu (e.g. Wi-Fi, a third-party app).
5. **Reordering:** move an item one slot via synthesised ⌘-drag; measure reliability over 100 runs.
6. **Notch geometry:** read `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` and detect items hidden behind the notch.

**Exit criteria:** a short written note per primitive: works / works with caveats / doesn't work, and which permission it needs. If 4 or 5 fail, the Bar and the layout editor need a different design. Re-plan before Phase 1.

### Phase 1 — MVP: hide & reveal (1–2 weeks)
> Revised after Phase 0 (see `docs/spikes.md`): on macOS 27 the divider trick is gone. Hiding uses the
> private `MBAssessmentModeAssertion` allow-list, and sections are per app.
- Agent app (`LSUIElement`), launch at login (`SMAppService`).
- Accio icon + a simple list of menu bar apps (from MenuBarAgent's AX tree) with a Shown / Hidden toggle.
  Hidden = not in the assertion's allow-list.
- Reveal by **click** on the icon and by **global hotkey**; auto-rehide after N seconds or on outside click.
- Persist state; restore correctly across relaunch, sleep/wake, display changes.
- Minimal SwiftUI Settings: hotkey, rehide delay, launch at login.
- **Ship to yourself and daily-drive it.**

### Phase 2 — Item discovery, layout editor, Always Hidden (2–3 weeks) ✅ done, adapted to macOS 27

As built: sections are per app (the allow-list's granularity), so there is no divider: **Always Hidden**
is a second reveal level (⌥-click) that keeps those apps out of the allow-list. Discovery reads
MenuBarAgent's AX tree for what's drawn and each app's `AXExtrasMenuBar` for apps whose items are hidden;
`ItemRegistry` remembers hidden items' places. Item identity is bundle ID + index (or the system
identifier). `ItemMover` shows every item while it ⌘-drags (spikes §5b). No Screen Recording step:
hidden items can't be captured on 27, so tiles use app icons and SF Symbols.

Original plan:
- `ItemDiscovery` + `ItemRegistry` (event-driven rescans as in §3).
- Second divider → **Always Hidden** section.
- **Layout editor** in Settings: three rows (Shown / Hidden / Always Hidden) showing every item with app icon + name (+ live image if Screen Recording granted); drag between rows → `ItemMover` performs the real move.
- Stable item identity across launches (bundle ID + item title/index heuristics; handle apps with multiple items).
- Onboarding flow for Accessibility (required for moving/clicking) and Screen Recording (optional).

### Phase 3 — The Bar (2–3 weeks) ✅ done, adapted to macOS 27

As built: the Bar is a **standard `NSMenu`** under Accio's icon (`HiddenItemsMenu`), one row per item
with its app icon or an SF Symbol and its name. A first version used a custom translucent panel with a
row of icons; next to the system's monochrome glyphs it looked out of place, and hidden items can't be
captured on 27 to draw real glyphs. (macOS's own overflow chevron doesn't use a panel either: it draws
the extra items in the menu bar, over the app menus.) Two modes (Settings → General): hidden items show
**in the menu bar** (default), with revealed items that don't fit (behind the notch or stacked on the
overflow chevron) offered in the menu right after the user asked for them ("notch mode"), or **in the
menu**, leaving the menu bar alone. ⌥ in the menu turns each row into a secondary click.
`ItemOpener` opens items: `AXPress` / `AXShowMenu` for apps' items, even hidden ones (falling back to a
click when an app shows nothing, like Passwords); Apple's items are shown for a moment (added to the allow-list, or shown alone when they
don't fit), clicked, and hidden again once their menu closes. Optional triggers: resting the pointer on
empty menu bar space, and swiping down/up on the menu bar. Keyboard navigation, VoiceOver and dismissal
come with the system menu. Main display only for now.

Not done: multi-display (Accio only manages the main display's menu bar so far), and per-item titles
in the menu (apps with several items get numbered rows with the same icon).

Original plan:
- Borderless, non-activating `NSPanel` below the menu bar, aligned to the Accio icon or screen edge (setting).
- Shows Hidden (+ optionally Always Hidden) items as captured images; without Screen Recording, falls back to app icon + name.
- Click / right-click / ⌥-click forwarding via `ClickForwarder`; the item's own menu must appear in the right place.
- Reveal triggers: **hover** over empty menu bar, **scroll/swipe** on the menu bar, click, hotkey.
- **Notch mode:** items that would land behind the notch are automatically shown in the Bar instead.
- Multi-display: Bar opens on the display with the active menu bar.

### Phase 4 — Search + per-item hotkeys (1–2 weeks)
- Spotlight-style panel (hotkey), fuzzy match on app name / item title, ↑↓ + Return to open the item's menu.
- Assign a hotkey to any individual item ("open Wi-Fi menu with ⌃⌥W").
- Fully keyboard-navigable; VoiceOver labels.

### Phase 5 — Polish pass 1 + public beta (2 weeks)
- Animations (respect Reduce Motion), light/dark, Increase Contrast, menu bar transparency setting.
- Edge cases: full-screen apps, auto-hiding menu bar, Stage Manager, Spaces, screen sharing, apps that recreate their status item, login burst.
- **Item spacing** control (Default / Small / Tiny) via `NSStatusItemSpacing` + guided relaunch of affected apps.
- Sparkle updates, notarized DMG, Homebrew cask, crash reporting (opt-in, privacy-respecting; or none).
- Performance audit against §1 budgets. **Public beta.**

### Phase 6 — Groups (2 weeks)
- Create a group in the layout editor → one status item (custom SF Symbol / emoji / label) that opens a mini Bar with its members.
- Members live in Always Hidden; the group reuses `BarPanel` + `ClickForwarder`.

### Phase 7 — Show for updates (1–2 weeks)
- Per-item toggle: when a hidden item's image changes meaningfully, show it in the menu bar for N seconds (or until clicked).
- Perceptual hash + threshold to ignore clock ticks / spinners if the user wants; per-item sensitivity.
- Must stay within the CPU budget with 5 watched items.

### Phase 8 — Profiles & triggers (2–3 weeks)
- **Profiles:** named snapshots of section assignment + order + groups; switch from the menu, hotkey or trigger.
- **Triggers** (each a small, independently testable module):
  - Power: on battery / below X% (IOKit `IOPSNotificationCreateRunLoopSource`)
  - Wi-Fi SSID (CoreWLAN; needs Location permission on modern macOS)
  - App launched / frontmost (`NSWorkspace`)
  - Microphone / camera in use (CoreAudio property listeners / CoreMediaIO)
  - Time of day / schedule
  - Display configuration (docked vs laptop-only)
  - Shell script returns true (opt-in, runs on interval the user sets)
  - Focus mode (investigate in Phase 0-style spike; no clean public API)
- Actions: show item temporarily, move item to section, switch profile.

### Phase 9 — Appearance & automation (2 weeks)
- **Menu bar styling:** tint / gradient / border / shadow / rounded "floating" bar, via a click-through overlay window at the right level, per-display.
- **Spacers & labels:** decorative status items (gap, divider line, text, SF Symbol, emoji).
- **Automation:** App Intents (Shortcuts + Siri: switch profile, reveal, open item), `accio://` URL scheme, basic AppleScript dictionary.

### Phase 10 — 1.0 release (1–2 weeks)
- Polish pass 2: settings copy, empty states, error states, onboarding video/GIFs.
- Import from Bartender / Ice config if feasible.
- Website / README, screenshots, changelog, Homebrew cask PR.

**Total: roughly 4–6 months to 1.0** part-time; usable for yourself after Phase 1 (~2–3 weeks).

### Post-1.0 ideas
- Custom script-backed menu bar items (SwiftBar/xbar-style).
- Notch widget area.
- iCloud sync of config.

---

## 5. Testing strategy

- **Unit tests** for `ItemRegistry`, layout/profile logic, trigger evaluation, hashing, persistence; window server faked via `WindowServerClient`.
- **Integration harness:** a small helper app that spawns N dummy status items with known titles/images, so discovery, moving, clicking and update detection can be tested end-to-end on a real machine.
- **Manual matrix** before each release: notch vs non-notch, 1 vs 2 displays, full-screen app, Stage Manager on/off, auto-hide menu bar, light/dark, Reduce Motion, fresh install with no permissions.
- **Performance check** before each release against §1 budgets (scripted with `ps`/`powermetrics` + Instruments trace).
- Test on each macOS beta as soon as it drops; menu bar internals are the main breakage risk.

---

## 6. Polish checklist (applies to every phase)

- Every window/panel: correct level, no focus stealing, closes on Esc and outside click.
- All animations ≤ 200 ms, interruptible, disabled under Reduce Motion.
- Pixel-aligned to the real menu bar on every display scale (1x, 2x, notch).
- No flicker on reveal/hide or during login.
- VoiceOver labels and full keyboard navigation in Settings, Bar and Search.
- Clear, honest permission explanations; app degrades gracefully when denied.
- Settings changes apply instantly, no "Apply" button.

---

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Apple changes menu bar internals again (as in macOS 26) | Core features break | `WindowServerClient` abstraction; test every beta; Phase 0 spikes kept as regression probes. |
| Synthesised ⌘-drag reordering is flaky | Layout editor unreliable | Retry with verification (re-read frames after each move); move one item at a time; fall back to "drag it yourself" guidance. |
| Click forwarding opens menus in wrong place / not at all | Bar and Search feel broken | Bring the real item on-screen before clicking; per-app quirk list. |
| Screen Recording permission scares users | Lower adoption | Optional by design; icon+name fallback everywhere. |
| UpdateWatcher costs CPU | Breaks "lightweight" promise | Opt-in per item, low rate, hash-based, paused when idle/locked. |
| Private APIs | No App Store | Accept; distribute via Developer ID + Homebrew. |

---

## 8. Milestone summary

| Milestone | Phases | Outcome |
|---|---|---|
| M0 Feasibility | 0 | Know what works on macOS 27 |
| M1 Daily driver | 1 | Replaces Hidden Bar for you |
| M2 Organiser | 2–4 | Layout editor, Bar, Search: roughly Ice-level |
| M3 Public beta | 5 | Polished, notarized, auto-updating |
| M4 Bartender-level | 6–9 | Groups, show for updates, profiles, triggers, styling, automation |
| M5 1.0 | 10 | Public release |

---

## 9. Decisions

| Decision | Outcome |
|---|---|
| Name | **Accio**, bundle ID `com.accio.app` |
| License | MIT; do not copy code from Ice/Thaw (GPL-3.0) |
| Visibility | Private GitHub repo until the MVP works |
| Build | SwiftPM + `scripts/build.sh` bundle assembly (no Xcode project), same as NotchCove |

Still open:
1. **Apple Developer account** for signing and notarization (needed by Phase 5). Now also needed for
   daily use: unsigned builds hide their own icon, because the allow-list ignores apps without a team
   signature (`docs/spikes.md` §1d). **Decided: no paid account for now.** Accio draws a stand-in
   icon instead, and `scripts/dev-signing.sh` keeps the Accessibility grant across rebuilds.
