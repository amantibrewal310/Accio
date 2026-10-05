import AppKit

/// The displays and their menu bars. macOS 27 draws a menu bar with every
/// status item on each display, even when displays share Spaces; the one
/// the user is working in is the one under the pointer.
@MainActor
enum Displays {
    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.id(of: $0) == id }
    }

    /// The display under the pointer: where the user clicked Accio, pressed
    /// the hotkey or swiped, so that's where items show and menus open.
    static var active: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.screens.first
    }

    static var activeID: CGDirectDisplayID {
        active.map(id(of:)) ?? CGMainDisplayID()
    }

    /// The menu bar's height on `screen`. Displays without a notch don't say
    /// (their visible frame can include the bar), so this falls back on the
    /// height MenuBarAgent last gave the bar there.
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        return max(screen.safeAreaInsets.top, reserved, barHeights[id(of: screen)] ?? 0, NSStatusBar.system.thickness)
    }

    private static var barHeights: [CGDirectDisplayID: CGFloat] = [:]

    /// Re-read the menu bars' heights, after displays change. A few AX reads.
    static func refresh() {
        barHeights = [:]
        for bar in MenuBarItems.barFrames() {
            guard let screen = NSScreen.screens.first(where: {
                CGDisplayBounds(id(of: $0)).origin == bar.origin
            }) else { continue }
            barHeights[id(of: screen)] = bar.height
        }
    }
}
