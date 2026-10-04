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
| 1 | Divider hiding | ⚠️ Unverified | Divider resizes, but the visual effect couldn't be confirmed (see below) |
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

## 1. Divider hiding ⚠️ unverified

Test: a separate `spike dummies --divider` process creates a divider, then D1–D3 (so they sit to its left),
and toggles the divider via signals while AX is read from outside.

- Divider length change applies (AX width 28 → **5002**: the system caps it, not 10,000) and reverts.
- D1–D3 positions barely changed, but the bar was already full so they were overflowing to begin with;
  the result is inconclusive.
- `screencapture` of the menu bar from this session returns an empty black bar, so visual verification
  needs a human looking at the screen. **Next: rerun with someone watching, ideally with fewer items
  in the menu bar.**

## Implications for the plan so far

- `ItemDiscovery` must be **Accessibility-based**, not window-based. The `WindowServerClient`
  abstraction in the plan stays, but its first implementation is AX.
- Accessibility permission becomes **required** for discovery (it was already required for moving/clicking).
- Item images (Bar, Groups, Search, Show for updates) can no longer capture per-item windows. Options to
  evaluate in spike 3: capture the `Menubar` window / display region and crop by AX frame (only works
  for items currently on-screen), or fall back to app icons.
