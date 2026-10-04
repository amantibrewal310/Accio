import AppKit

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSManagedDisplayGetCurrentSpace") private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> UInt64
@_silgen_name("CGSSpaceGetType") private func CGSSpaceGetType(_ cid: Int32, _ space: UInt64) -> Int32

/// Whether the main display's menu bar is on screen right now. macOS hides
/// it in full screen (and on the desktop, if the user chose to) until the
/// pointer reaches the top edge, but says nothing about it: the menu bar's
/// windows and AX frames stay the same either way. So this follows the
/// rules macOS uses: auto-hiding on this Space, and the pointer at the top.
@MainActor
final class MenuBarPresence {
    static let shared = MenuBarPresence()

    /// Called when the menu bar shows or hides.
    var onChange: (@MainActor (Bool) -> Void)?
    private(set) var isShown = true

    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?

    /// `CGSSpaceGetType` for a full-screen app's Space.
    private static let fullScreenSpaceType: Int32 = 4

    private init() {}

    func start() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarPresence.shared.update() }
        }
        update()
    }

    /// Re-check the Space and the user's setting; watch the pointer only
    /// while the menu bar auto-hides.
    private func update() {
        let autoHides = Self.autoHides()
        if autoHides, monitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
                MainActor.assumeIsolated { MenuBarPresence.shared.pointerMoved() }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
                MainActor.assumeIsolated { MenuBarPresence.shared.pointerMoved() }
                return event
            }) { monitors.append(local) }
        } else if !autoHides {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
        setShown(!autoHides || MenuBarState.isMouseInMenuBar)
    }

    /// macOS slides the menu bar down when the pointer touches the top edge,
    /// and up again once it leaves the bar (unless a menu is open).
    private func pointerMoved() {
        guard let screen = NSScreen.screens.first else { return }
        let point = NSEvent.mouseLocation
        guard NSMouseInRect(point, screen.frame, false) else { return }
        let fromTop = screen.frame.maxY - point.y
        if !isShown, fromTop <= 1 {
            setShown(true)
        } else if isShown, !MenuBarState.isMouseInMenuBar, !MenuBarState.isMenuOpen {
            setShown(false)
        }
    }

    private func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        onChange?(shown)
    }

    /// The setting in System Settings → Control Centre → "Automatically hide
    /// and show the menu bar" is two flags: hide on the desktop, and stay
    /// visible in full screen.
    private static func autoHides() -> Bool {
        let defaults = UserDefaults.standard
        if isFullScreenSpace() {
            return !defaults.bool(forKey: "AppleMenuBarVisibleInFullscreen")
        }
        return defaults.bool(forKey: "_HIHideMenuBar")
    }

    private static func isFullScreenSpace() -> Bool {
        let connection = CGSMainConnectionID()
        let space = CGSManagedDisplayGetCurrentSpace(connection, "Main" as CFString)
        return CGSSpaceGetType(connection, space) == fullScreenSpaceType
    }
}
