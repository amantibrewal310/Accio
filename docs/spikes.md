# Phase 0: Feasibility Spikes

Probes for the low-level primitives Accio depends on, run on the target OS.
Code: `spikes/` (`cd spikes && swift build && .build/debug/spike`).

**Test machine:** MacBook (notch), built-in display 1470×956 pt @2x, macOS 27.0.1 (26A434), arm64.
Accessibility and Screen Recording granted to the host process.

## Summary

| # | Primitive | Status | Notes |
|---|---|---|---|
| 2 | Enumerate items via window list | ❌ Broken on macOS 27 | No per-item windows exist any more |
| 2b | Enumerate items via Accessibility | ✅ Works | 115 ms full scan; system items are anonymous |
| 6 | Notch geometry | ✅ Works | |
| 1 | Divider hiding | ❌ Broken on macOS 27 | Oversized item is dropped by the system instead of pushing others off-screen |
| 1b | Hiding via `MBAssessmentModeAssertion` allow-list | ⏳ In progress | Private API activates successfully from an unentitled process; visual effect not yet confirmed |
| 3 | Image capture | ⏳ Pending | Needs redesign: no per-item window to capture |
| 4 | Click forwarding | ⏳ Pending | `AXPress` is the likely route for third-party items |
| 5 | Reordering (⌘-drag) | ⏳ Pending | |

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

## 1b. `MBAssessmentModeAssertion` ⏳

`/System/Library/PrivateFrameworks/MenuBarClientCore.framework` (Objective-C classes, loadable with
`dlopen` + `NSClassFromString`):

- `MBAssessmentModeConfiguration initWithAllowedSystemItems:(NSArray<NSNumber>) allowedBundleIdentifiers:(NSArray<NSString>)`
- `MBAssessmentModeAssertion init`, `activateWithConfiguration:completionHandler:`, `invalidate`
- Also present: `MBMenuBarItemManager` (`setItems:`, `setGloballyHidden:`, `startMenuTrackingForItemID:`,
  `navigateInDirection:`…), `MBUtilities getPreferredTrailingItemPositions` / `clearPreferredTrailingItemPositions`.

This looks like the menu bar side of exam ("assessment") mode: **show only an allow-list of items**. If it
works for us, it is a clean hiding mechanism: allow-list = Accio's Shown section, and invalidating the
assertion reveals everything.

- Activating it from a plain, unentitled, unsigned process with allow-list `[org.p0deje.Maccy]` returned
  **success**.
- Visual effect not yet confirmed (screenshots were taken while the Mac was in full-screen mode).
- To find out: does it hide the non-allowed items? Does it hide system items too (and which `NSNumber` IDs
  map to which system item)? Does it have other side effects of exam mode? Is it released when the
  process exits?

## Implications for the plan so far

- `ItemDiscovery` must be **Accessibility-based**, not window-based. The `WindowServerClient`
  abstraction in the plan stays, but its first implementation is AX.
- Accessibility permission becomes **required** for discovery (it was already required for moving/clicking).
- Enumeration should read **MenuBarAgent's AX tree** (slots + owner pid), not each app's `AXExtrasMenuBar`.
- The plan's divider-based Phase 1 doesn't work on macOS 27. Hiding is either the
  `MBAssessmentModeAssertion` allow-list (if 1b confirms) or icemelt-style spacers into the system overflow.
- Item images (Bar, Groups, Search, Show for updates) can no longer capture per-item windows. Hidden
  items aren't drawn at all, so the fallback is app icons / SF Symbols.
