import AppKit

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSManagedDisplayGetCurrentSpace") private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> UInt64
@_silgen_name("CGSSpaceGetType") private func CGSSpaceGetType(_ cid: Int32, _ space: UInt64) -> Int32

/// Whether each display's menu bar is on screen right now. macOS hides it in
/// full screen (and on the desktop, if the user chose to) until the pointer
/// reaches the top edge, but says nothing about it: the menu bar's windows
/// and AX frames stay the same either way. So this follows the rules macOS
/// uses: auto-hiding on the display's current Space, and the pointer at the
/// top of that display.
@MainActor
final class MenuBarPresence {
    static let shared = MenuBarPresence()

    /// Called when a display's menu bar shows or hides.
    var onChange: (@MainActor (CGDirectDisplayID, Bool) -> Void)?

    /// Displays whose menu bar auto-hides on their current Space.
    private var autoHiding: Set<CGDirectDisplayID> = []
    /// Displays whose menu bar has slid away.
    private var hidden: Set<CGDirectDisplayID> = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// `CGSSpaceGetType` for a full-screen app's Space.
    private static let fullScreenSpaceType: Int32 = 4

    private init() {}

    func isShown(on display: CGDirectDisplayID) -> Bool {
        !hidden.contains(display)
    }

    func start() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarPresence.shared.update() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarPresence.shared.update() }
        })
        update()
    }

    /// Re-check the Spaces and the user's setting; watch the pointer only
    /// while some menu bar auto-hides.
    private func update() {
        autoHiding = Set(NSScreen.screens.filter(Self.autoHides).map(Displays.id(of:)))
        if !autoHiding.isEmpty, monitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
                MainActor.assumeIsolated { MenuBarPresence.shared.pointerMoved() }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
                MainActor.assumeIsolated { MenuBarPresence.shared.pointerMoved() }
                return event
            }) { monitors.append(local) }
        } else if autoHiding.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
        let pointerBar = MenuBarState.isMouseInMenuBar ? Displays.active.map(Displays.id(of:)) : nil
        for screen in NSScreen.screens {
            let display = Displays.id(of: screen)
            setShown(!autoHiding.contains(display) || display == pointerBar, on: display)
        }
        // Forget displays that are gone.
        hidden.formIntersection(NSScreen.screens.map(Displays.id(of:)))
    }

    /// macOS slides a menu bar down when the pointer touches the top edge of
    /// its display, and up again once it leaves the bar (unless a menu is open).
    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        let pointerDisplay = screen.map(Displays.id(of:))
        if let screen, let pointerDisplay, hidden.contains(pointerDisplay), screen.frame.maxY - point.y <= 1 {
            setShown(true, on: pointerDisplay)
        }
        for display in autoHiding where !hidden.contains(display) {
            guard display != pointerDisplay || !MenuBarState.isMouseInMenuBar, !MenuBarState.isMenuOpen else { continue }
            setShown(false, on: display)
        }
    }

    private func setShown(_ shown: Bool, on display: CGDirectDisplayID) {
        guard shown != isShown(on: display) else { return }
        if shown { hidden.remove(display) } else { hidden.insert(display) }
        onChange?(display, shown)
    }

    /// The setting in System Settings → Control Centre → "Automatically hide
    /// and show the menu bar" is two flags: hide on the desktop, and stay
    /// visible in full screen.
    private static func autoHides(_ screen: NSScreen) -> Bool {
        let defaults = UserDefaults.standard
        if isFullScreenSpace(on: screen) {
            return !defaults.bool(forKey: "AppleMenuBarVisibleInFullscreen")
        }
        return defaults.bool(forKey: "_HIHideMenuBar")
    }

    /// Displays share one set of Spaces ("Main") unless each has its own,
    /// named by the display's UUID.
    private static func isFullScreenSpace(on screen: NSScreen) -> Bool {
        let connection = CGSMainConnectionID()
        var name = "Main"
        if NSScreen.screensHaveSeparateSpaces,
           let uuid = CGDisplayCreateUUIDFromDisplayID(Displays.id(of: screen))?.takeRetainedValue() {
            name = CFUUIDCreateString(nil, uuid) as String
        }
        let space = CGSManagedDisplayGetCurrentSpace(connection, name as CFString)
        return CGSSpaceGetType(connection, space) == fullScreenSpaceType
    }
}
