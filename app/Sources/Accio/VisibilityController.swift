import AppKit
import Combine

/// Decides what the menu bar shows: Hidden items stay hidden until the user
/// reveals them (click or hotkey), Always Hidden ones until the user reveals
/// everything (⌥-click). Both hide again after a delay or an outside click.
@MainActor
final class VisibilityController: ObservableObject {
    static let shared = VisibilityController()

    enum RevealLevel { case none, hidden, all }

    @Published private(set) var revealLevel = RevealLevel.none
    var isRevealed: Bool { revealLevel != .none }
    @Published private(set) var isTrusted = MenuBarItems.isTrusted
    /// False when this macOS doesn't offer the hiding API.
    var isAvailable: Bool { hider != nil }

    var onRevealChange: (@MainActor (Bool) -> Void)?
    /// Called after every apply, with whether items are being hidden now.
    var onHidingChange: (@MainActor (Bool) -> Void)?

    private let hider = MenuBarHider()
    private let preferences = Preferences.shared
    private let registry = ItemRegistry.shared
    /// While ItemMover drags an item, everything is shown.
    private var isMoving = false
    private var rehideTimer: Timer?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?

    private init() {}

    func start() {
        if hider == nil { log("[Accio] MenuBarClientCore assessment API not found; hiding unavailable") }
        observeSystem()
        // See what's in the bar before hiding anything, so hidden items
        // have a known place.
        registry.update(visible: MenuBarItems.visible())
        apply()
        rescan()
    }

    // MARK: Reveal / hide

    func toggle() {
        isRevealed ? hide() : reveal()
    }

    /// Show Hidden items, or with `all` the Always Hidden ones too.
    func reveal(all: Bool = false) {
        let level: RevealLevel = all || revealLevel == .all ? .all : .hidden
        guard level != revealLevel else { return scheduleRehide() }
        revealLevel = level
        apply()
        scheduleRehide()
        updateClickMonitor()
        onRevealChange?(true)
        // Revealed items are drawn again: note where they are once they've faded in.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            if self.isRevealed { self.rescan() }
        }
    }

    func hide() {
        guard isRevealed else { return }
        revealLevel = .none
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
        if !isMoving, let allowList = allowList() {
            hider.hide(allowing: allowList)
        } else {
            hider.showAll()
        }
        onHidingChange?(hider.isHiding)
    }

    func beginMove() {
        isMoving = true
        apply()
    }

    func endMove() {
        isMoving = false
        apply()
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

    /// Everything that's running, minus what's hidden at the current reveal
    /// level. Allowing apps without items is harmless, and means a newly
    /// launched app shows up straight away.
    ///
    /// `nil` when nothing needs hiding: holding an assertion also hides Focus
    /// and other unlisted Apple items, so don't hold one without a reason.
    private func allowList() -> MenuBarHider.AllowList? {
        var hiddenApps = preferences.alwaysHiddenApps
        var hiddenSystemItems = preferences.alwaysHiddenSystemItems
        switch revealLevel {
        case .all: return nil
        case .hidden: break
        case .none:
            hiddenApps.formUnion(preferences.hiddenApps)
            hiddenSystemItems = Set(SystemItem.allCases).subtracting(preferences.shownSystemItems)
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard !hiddenSystemItems.isEmpty || !running.isDisjoint(with: hiddenApps) else { return nil }
        var bundleIDs = running.subtracting(hiddenApps)
        if let own = Bundle.main.bundleIdentifier { bundleIDs.insert(own) }
        return .init(bundleIDs: bundleIDs, systemItems: Set(SystemItem.allCases).subtracting(hiddenSystemItems))
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
        let trusted = MenuBarItems.isTrusted
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        rescan()
    }

    /// Refresh the item registry in the background.
    func rescan() {
        guard MenuBarItems.isTrusted else { return }
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            let (visible, apps) = await Task.detached(priority: .utility) {
                (MenuBarItems.visible(), MenuBarItems.apps())
            }.value
            guard !Task.isCancelled else { return }
            registry.update(visible: visible)
            registry.update(apps: apps)
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

    /// x of the leftmost item still showing on the main display (needs
    /// Accessibility). Ignores Accio's own item.
    static func leftmostVisibleItemX() -> CGFloat? {
        MenuBarItems.visible().first?.frame.minX
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
