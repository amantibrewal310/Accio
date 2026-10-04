import AppKit
import Combine

/// Decides what the menu bar shows: hidden apps stay hidden until the user
/// reveals them (click or hotkey), and hide again after a delay or an
/// outside click.
@MainActor
final class VisibilityController: ObservableObject {
    static let shared = VisibilityController()

    @Published private(set) var isRevealed = false
    /// Running apps with menu bar items, from the last scan.
    @Published private(set) var menuBarApps: [MenuBarApp] = []
    @Published private(set) var isTrusted = MenuBarApps.isTrusted
    /// False when this macOS doesn't offer the hiding API.
    var isAvailable: Bool { hider != nil }

    var onRevealChange: (@MainActor (Bool) -> Void)?

    private let hider = MenuBarHider()
    private let preferences = Preferences.shared
    private var rehideTimer: Timer?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?

    private init() {}

    func start() {
        if hider == nil { log("[Accio] MenuBarClientCore assessment API not found; hiding unavailable") }
        observeSystem()
        apply()
        rescan()
    }

    // MARK: Reveal / hide

    func toggle() {
        isRevealed ? hide() : reveal()
    }

    func reveal() {
        guard !isRevealed else { return scheduleRehide() }
        isRevealed = true
        apply()
        scheduleRehide()
        updateClickMonitor()
        onRevealChange?(true)
    }

    func hide() {
        guard isRevealed else { return }
        isRevealed = false
        rehideTimer?.invalidate()
        rehideTimer = nil
        apply()
        updateClickMonitor()
        onRevealChange?(false)
    }

    /// Release the assertion now rather than waiting for the system to notice we quit.
    func showAllForQuit() {
        hider?.showAll()
    }

    /// Bring the hider in line with the current state and preferences.
    func apply() {
        guard let hider else { return }
        if isRevealed || !hasAnythingToHide {
            hider.showAll()
        } else {
            hider.hide(allowing: allowList())
        }
    }

    func preferencesChanged(_ change: Preferences.Change) {
        switch change {
        case .visibility: apply()
        case .rehide:
            if isRevealed { scheduleRehide() }
            updateClickMonitor()
        case .shortcut: break
        }
    }

    /// Everything that's running, minus the hidden apps. Allowing apps without
    /// items is harmless, and means a newly launched app shows up straight away.
    private func allowList() -> MenuBarHider.AllowList {
        var bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        bundleIDs.subtract(preferences.hiddenApps)
        if let own = Bundle.main.bundleIdentifier { bundleIDs.insert(own) }
        return .init(bundleIDs: bundleIDs, systemItems: preferences.shownSystemItems)
    }

    /// Holding an assertion also hides Focus and other unlisted Apple items,
    /// so don't hold one unless something is actually meant to be hidden.
    private var hasAnythingToHide: Bool {
        if preferences.shownSystemItems.count < SystemItem.allCases.count { return true }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.isDisjoint(with: preferences.hiddenApps)
    }

    // MARK: Rehide

    private func scheduleRehide(after delay: TimeInterval? = nil) {
        rehideTimer?.invalidate()
        rehideTimer = nil
        let seconds = delay ?? TimeInterval(preferences.rehideDelay)
        guard isRevealed, seconds > 0 else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { VisibilityController.shared.rehideIfIdle() }
        }
        rehideTimer?.tolerance = 0.2
    }

    /// Hide again unless the user is still busy with a revealed item.
    private func rehideIfIdle() {
        guard isRevealed else { return }
        if MenuBarState.isMenuOpen || MenuBarState.isMouseInMenuBar {
            scheduleRehide(after: 1)
        } else {
            hide()
        }
    }

    private func updateClickMonitor() {
        let wanted = isRevealed && preferences.rehidesOnOutsideClick
        if wanted, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { VisibilityController.shared.outsideClick() }
            }
        } else if !wanted, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func outsideClick() {
        guard !MenuBarState.isMouseInMenuBar else { return }
        // A click in an item's menu picks an entry; hide once that menu closes.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.rehideIfIdle()
        }
    }

    // MARK: Discovery

    /// Pick up an Accessibility grant made in System Settings.
    func refreshTrust() {
        let trusted = MenuBarApps.isTrusted
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        rescan()
    }

    /// Refresh `menuBarApps` in the background.
    func rescan() {
        guard MenuBarApps.isTrusted else { return }
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            let apps = await Task.detached(priority: .utility) { MenuBarApps.scan() }.value
            guard !Task.isCancelled else { return }
            menuBarApps = apps
            var known = preferences.knownApps
            for app in apps { known[app.bundleID] = app.name }
            if known != preferences.knownApps { preferences.knownApps = known }
        }
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { VisibilityController.shared.appLaunched(bundleID) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VisibilityController.shared.rescanSoon() }
        })
        // The assertion lives in MenuBarAgent; make sure it still holds after
        // sleep and display changes.
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VisibilityController.shared.reassert() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VisibilityController.shared.reassert() }
        })
    }

    private func appLaunched(_ bundleID: String?) {
        if bundleID == "com.apple.MenuBarAgent" {
            // A restarted MenuBarAgent has forgotten our assertion.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.reassert()
            }
            return
        }
        apply()
        rescanSoon()
    }

    private func reassert() {
        hider?.reassert()
    }

    /// Apps add their items a moment after launching.
    private func rescanSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.rescan()
        }
    }
}

/// Read-only questions about what the user is doing in the menu bar.
@MainActor
enum MenuBarState {
    /// The menu bar's height on the screen under the mouse.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }

    static var isMouseInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        return screen.frame.maxY - point.y <= menuBarHeight(of: screen) + 1
    }

    /// Whether a menu or popover hangs from the menu bar: some other app's
    /// floating window whose top edge sits just below the bar.
    static var isMenuOpen: Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard
                let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                window[kCGWindowOwnerName as String] as? String != "Window Server",
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds),
                rect.height > 1
            else { return false }
            return rect.minY >= 20 && rect.minY <= 60
        }
    }
}

func log(_ message: String) {
    NSLog("%@", message)
}
