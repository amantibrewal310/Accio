# Phase 0: Feasibility Spikes

Probes for the low-level primitives Accio depends on, run on the target OS.
Code: `spikes/` (`cd spikes && swift build && .build/debug/spike`).

**Test machine:** MacBook (notch), built-in display 1470×956 pt @2x, macOS 27.0.1 (26A434), arm64.
Accessibility and Screen Recording granted to the host process.

## Summary

**Verdict: feasible on macOS 27.** Every primitive Accio needs has a working approach.

| # | Primitive | Status | Approach on macOS 27 |
|---|---|---|---|
| 2 | Enumerate via window list | ❌ Broken | No per-item windows exist any more |
| 2b | Enumerate via each app's `AXExtrasMenuBar` | ✅ Works | ~115 ms full scan; system items anonymous |
| 2c | Enumerate via MenuBarAgent's AX tree | ✅ Works | Owner bundle ID per slot + system identifiers. **Use this** |
| 6 | Notch geometry | ✅ Works | `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` |
| 1 | Divider hiding | ❌ Broken | Oversized item is dropped by the system |
| 1b | Hiding via `MBAssessmentModeAssertion` | ✅ Works | Allow-list; union of active assertions; crash-safe |
| 1d | Allow-listing ad-hoc signed apps | ❌ Ignored | Only team-signed apps can be allow-listed, Accio included |
| 1c | System item IDs | ✅ Mapped | 0–8; Focus not allow-listable |
| 4 | Click forwarding | ✅ Works | `AXPress` (no cursor move) for apps; CGEvent at slot for system items |
| 4b | Reveal one hidden app, then open it | ✅ Works | Activate new assertion, then invalidate the old one; no flash |
| 5 | Reordering (⌘-drag) | ✅ Works | 10/10 with a slow drag (12 steps × 30 ms); fast drags fail |
| 3 | Image capture of hidden items | ❌ Not possible | Hidden items aren't drawn; use app icons / SF Symbols |

## 2. Window-list enumeration ❌

- `CGSGetProcessMenuBarWindowList` (private, used by Ice) returns **one** window: `Menubar`, owned by
  `Window Server`, spanning the full width (wid 5143, 1470 pt).
- `CGWindowListCopyWindowInfo` finds **no** status-level windows owned by apps. A dump of every small
  window touching the top edge found nothing per-item, only NotchCove's own notch window.
- **Conclusion:** on macOS 27 status items are no longer separate windows; they're drawn into a single
  WindowServer-owned menu bar surface. This is very likely what broke Ice. Any design that relies on
  per-item window IDs (enumeration, per-window capture, window-targeted clicks) won't work.

## 2b. Accessibility enumeration ✅

Each app's `AXExtrasMenuBar` attribute → children, with `AXPosition` / `AXSize`.

- Found 12 on-screen items with correct positions and owner PIDs.
- Third-party items expose `AXPress` (Tailscale, Gemini, Passwords, Maccy, Text Input).
- **System items** (Control Center, Wi-Fi, battery, clock…) are all owned by a `MenuBarAgent` process
  (pid 1132). They report **no title, description, identifier or actions**. Identifying them will need
  heuristics (order, width) or another source; opening them may need synthetic clicks.
- Performance:
  - Sequential scan over all 118 running apps: **6.4 s**. Cause: XPC helpers (Safari WebContent etc.)
    never answer and each burns the 250 ms messaging timeout.
  - Concurrent per-app queries: 634 ms.
  - Concurrent + only `.app` bundles: **~115 ms**, same 12 items. Acceptable, since the real app does
    full scans only on events and otherwise rescans a single app.
- Item frames for items that don't fit look unreliable: on a full menu bar, newly added test items
  reported overlapping x positions (D1 at 848, D2 and D3 both at 846), i.e. they are overflowing.

## 6. Notch geometry ✅

`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` give the notch as x 645.5–824.5, height 32 pt.
Converting to global top-left coordinates works; intersecting with AX item frames is straightforward.

## 1. Divider hiding ❌

Test: a separate `spike dummies --divider` process creates a divider, then D1–D3 (so they sit to its left),
and toggles the divider via signals. Verified with screenshots (the earlier black captures were because the
Mac was in full-screen mode, where the menu bar is hidden).

| Before | Divider expanded | Collapsed |
|---|---|---|
| `D3 D2 D1 ‖ …` | `D3 D2 D1 …`: the **divider itself vanishes**, D1–D3 slide right | `D3 D2 D1 ‖ …` |

- macOS caps the item (AX width 5002) and then drops it, because macOS 27 removes any item wider than half
  the display.
- AX positions are not trustworthy during the change (D1–D3 reported moving slightly *right*).

## How macOS 27 works (from research)

- The whole menu bar is one window drawn by `MenuBarAgent` (`com.apple.MenuBarAgent`).
- Built-in overflow: when items don't fit (notch, wide app menus), macOS collapses the surplus behind a
  **"Show Hidden Menu Bar Items"** chevron. Users can't choose which items go there. Items pack from the
  trailing (right) end; the first one that doesn't fit, and everything left of it, overflows.
- Collapsed items aren't drawn at all; AX reports them stacked on top of the chevron.
- Status of others (Oct 2026): Ice broken and unmaintained; Thaw 2.x and Bartender 7 work.
  Bartender 7 / BetterTouchTool use an undocumented "menu bar layout" approach.
- **icemelt** (GPL fork of Ice, studied for approach only, no code copied):
  - Enumerates through **MenuBarAgent's AX tree**: one AX window per display, one child per item slot; the
    slot's first child is owned by the app that created the item (`AXUIElementGetPid`), so the owner is
    known without messaging the app. System extras carry identifiers like `com.apple.menuextra.clock`.
    The chevron is the slot with no child.
  - Hides by filling the available room with blank spacer `NSStatusItem`s (each under half the display
    width, positioned via `NSStatusItem Preferred Position <autosaveName>` defaults) so the hidden
    section is pushed into the system overflow. Fragile: the room changes with every app switch, multi-display
    is broken, and it flickers.
  - Clicks with `CGEvent` at the slot centre (opening the chevron first for hidden items). No image capture
    on 27: uses app icons / SF Symbols. Reorders with synthesised ⌘-drag.

## 1b. `MBAssessmentModeAssertion` ✅

`/System/Library/PrivateFrameworks/MenuBarClientCore.framework` (Objective-C classes, loadable with
`dlopen` + `NSClassFromString`; probes in `spikes/probes/`):

- `MBAssessmentModeConfiguration initWithAllowedSystemItems:(NSArray<NSNumber>) allowedBundleIdentifiers:(NSArray<NSString>)`
- `MBAssessmentModeAssertion init`, `activateWithConfiguration:completionHandler:`, `invalidate`
- Also present: `MBMenuBarItemManager` (`setItems:`, `setGloballyHidden:`, `startMenuTrackingForItemID:`,
  `navigateInDirection:`…), `MBUtilities getPreferredTrailingItemPositions` / `clearPreferredTrailingItemPositions`.

This is the menu bar side of exam ("assessment") mode: **show only an allow-list of items**.

Results, verified with screenshots:

- Works from a plain, unentitled, unsigned process. Completion handler reports success.
- With allow-list `[org.p0deje.Maccy]` the bar showed **only Maccy**. Everything else was hidden, **including
  system items** (clock, Wi-Fi, battery, Control Center). `invalidate` restores everything.
- Items fade out/in with a system animation (~1 s); this looks native.
- **Crash-safe:** killing the process without `invalidate` restored every item within 2 s.
- System items are allowed by `NSNumber` ID; see 1c for the mapping.

Limitations:

- Granularity is **per app** (bundle ID): can't show one of an app's items and hide another.
- Active assertions combine as a union (see 4b), so another holder can keep items visible.
- Private API: Apple could gate it behind an entitlement in any update. Keep the icemelt-style spacer
  approach as a documented fallback.
- Not tested yet: whether hidden items are still reachable through the system overflow chevron.

## 1d. The allow-list needs a team signature ❌ (found in Phase 1)

While an assertion is active, MenuBarAgent **ignores allow-listed bundle IDs of ad-hoc signed apps**.
Tested from a separate process, so the assertion holder doesn't matter:

| App in the allow-list | Signature | Stays visible |
|---|---|---|
| Maccy (`/Applications`) | Developer ID, team `MN3X4648SC` | ✅ |
| The same Maccy, copied and re-signed ad-hoc | ad-hoc, no team | ❌ hidden |
| `Accio.app` (`build/` or `/tmp`, registered with `lsregister`) | ad-hoc | ❌ hidden |
| A minimal ad-hoc test bundle (`com.accio.dummy`) | ad-hoc | ❌ hidden |

A **self-signed** certificate doesn't help either (tested: `TeamIdentifier=not set`, still hidden). Only
Apple-issued certificates carry a team ID: Developer ID ($99/yr) or the free "Apple Development"
certificate that Xcode creates for any Apple ID (needs Xcode; not tested).

Consequences:

- Accio's own status item hides whenever Accio hides anything. Accio works around it with a
  **stand-in icon**: a small borderless panel at status-bar level, placed left of the leftmost visible
  item (MenuBarAgent AX tree), or just right of the notch without Accessibility. The assertion only
  hides status items, so the panel stays. Its glyph colour is taken from the wallpaper's top strip when
  the picture is in an unprotected location; reading one from ~/Downloads etc. triggers a privacy prompt,
  so those fall back to white.
- Users' own ad-hoc signed apps (local builds, some Homebrew apps) can't be kept visible while hiding.

## 2c. MenuBarAgent AX tree ✅

Reading `com.apple.MenuBarAgent`'s AX windows → children (one per slot):

- Each slot's first child is owned by the item's app (`AXUIElementGetPid`) → bundle ID, without messaging
  the app.
- System items carry identifiers: `com.apple.menuextra.{clock,wifi,battery,bluetooth,controlcenter,focusmode}`.
- The agent currently holds **3 windows** for one display, so every slot appears 3 times. Deduplicate (or
  find out what the extra windows are).
- AX contents **don't reflect assertion-hidden state** reliably, so use our own state for "hidden", not AX.

## 1c. System item IDs ✅

`MBSystemItemIdentifier` is a 9-case Int enum (`CaseIterable`; case names stripped). Read via Swift runtime
reflection (`allCases` / `rawValue`) and `init(stringValue:)`. That init returns an `Optional` of an
Int-laid-out enum, so the nil flag comes back in a second register; a tiny C shim reads it
(`spikes/probes/system-item-names*`). The init consumes its String argument (+1), so callers must hand
over an owned copy.

| ID | `stringValue` | Verified on screen |
|---|---|---|
| 0 | `battery` | ✅ |
| 1 | `bluetooth` | ✅ |
| 2 | `clock` | ✅ |
| 3 | `displays` | (not in this bar) |
| 4 | `keyboard` | (not in this bar) |
| 5 | `volume` | (not in this bar) |
| 6 | `wifi` | ✅ |
| 7 | `screenMirroring` | (not in this bar) |
| 8 | ? (not found by guessing) | ✅ Control Center |

**Focus** (`com.apple.menuextra.focusmode`) has no ID, and allowing `com.apple.controlcenter`,
`com.apple.MenuBarAgent` and other candidate bundle IDs didn't bring it back: Focus is hidden whenever an
assertion is active. Same presumably for other system extras outside the enum.

## 4. Click forwarding ✅ and 4b. reveal-one flow ✅

Verified with screenshots (`spikes/probes/assertion-flow*.swift`):

| Step | Result |
|---|---|
| A = allow clock only | only the clock |
| B = allow clock + Maccy, activated while A is active | Maccy fades in |
| invalidate A | unchanged, so swap = activate new, then invalidate old, **with no flash** |
| CGEvent click at Maccy's MenuBarAgent slot centre | Maccy's menu opens |
| A = clock only and B = Maccy only, both active | clock **and** Maccy, so assertions combine as a **union** |
| `AXPress` on Maccy's element from its own `AXExtrasMenuBar` | menu opens in **6 ms**, cursor untouched |
| CGEvent click at Wi-Fi's slot (found by `com.apple.menuextra.wifi`) | Wi-Fi menu opens |

- Third-party items: prefer `AXPress`; no cursor movement.
- System items have no AX actions, so post a CGEvent click (HID tap) at the slot centre and warp the cursor back.
- Union semantics: Accio can't hide anything another assertion holder allows (e.g. real exam mode or
  another menu bar manager). Acceptable.

## 5. Reordering ✅

`spikes/probes/reorder.swift`, rotation test on 3 dummy items (rightmost → left of leftmost),
order read from the owning app's `AXExtrasMenuBar` titles:

| Drag | Result |
|---|---|
| ⌘ + mouse-down, 12 drag steps × 30 ms, mouse-up at target.minX + 3 | **10/10**, ~0.5 s per move |
| 4 steps × 10 ms | 1/10 |

AX order updates lag slightly behind the move; verify by polling.

## Implications for the plan

- **Hiding = `MBAssessmentModeAssertion`.** Shown section = allow-list (bundle IDs + system item IDs 0–8,
  always including Accio itself). Reveal all = invalidate. Change the set = activate the new assertion,
  then invalidate the old one.
- **Sections are per app**, not per item. **Focus** (and other system extras outside the enum) are hidden
  whenever hiding is on; the UI must say so.
- **Discovery = MenuBarAgent's AX tree**, deduplicated (the agent holds 3 windows per display),
  event-driven. Don't trust AX for hidden state; Accio's own state is the source of truth.
- **Open an item** = `AXPress` for apps, CGEvent click for system items. For a hidden item: add it to the
  allow-list, wait for the ~1 s fade, click, restore when its menu closes.
- **Reorder** = slow synthesised ⌘-drag, verified by polling.
- **No live images** of hidden items: the Bar and Search show app icons and SF Symbols.
- **Risk:** all of this rests on private API that Apple can gate in any update. Keep icemelt-style
  spacers as the documented fallback, and isolate the assertion behind one small module.
