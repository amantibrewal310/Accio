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
    /// After revealing in the menu bar, with the revealed items that don't
    /// fit (behind the notch or the overflow chevron); empty if all fit.
    var onOverflow: (@MainActor ([MenuBarItem]) -> Void)?
    /// Called after every apply, with whether items are being hidden now.
    var onHidingChange: (@MainActor (Bool) -> Void)?

    private let hider = MenuBarHider()
    private let preferences = Preferences.shared
    private let registry = ItemRegistry.shared
    /// While ItemMover drags an item, everything is shown.
    private var isMoving = false
    /// An item shown for a moment so it can be clicked (`ItemOpener`);
    /// `alone` when it doesn't fit next to the others.
    private var temporary: (item: MenuBarItem, alone: Bool)?
    private var rehideTimer: Timer?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?
    private var pendingRescan: Task<Void, Never>?
    private var pendingApply: Task<Void, Never>?

    private init() {}

    func start() {
        if hider == nil { log("[Accio] MenuBarClientCore assessment API not found; hiding unavailable") }
        observeSystem()
        Task { @MainActor in
            // See what's in the bar before hiding anything, so hidden items
            // have a known place. Accio's own item is drawn a moment after
            // it's created, and unsigned builds hide it while hiding, so wait
            // for it (briefly): the stand-in icon goes where it would be.
            for _ in 0..<20 where MenuBarItems.isTrusted && MenuBarItems.ownItemFrame() == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            registry.update(visible: MenuBarItems.visible(includingOwn: true), everythingShown: true)
            Displays.refresh()
            apply()
            rescan()
        }
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
        // Revealed items are drawn again: note where they are once they've
        // faded in, and whether they fit.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            guard self.isRevealed else { return }
            self.rescan { if self.isRevealed { self.checkOverflow() } }
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

    /// Whether `item` is drawn while the current assertion holds.
    func staysVisible(_ item: MenuBarItem) -> Bool {
        guard let hider, hider.isHiding, let allowList = hider.allowList else { return true }
        if item.isAccio { return MenuBarHider.keepsOwnIconVisible }
        switch item.owner {
        case .app(let bundleID): return allowList.bundleIDs.contains(bundleID)
        case .system: return item.systemItem.map(allowList.systemItems.contains) ?? false
        }
    }

    /// Show `item` until `endTemporary()`, so it can be clicked.
    func showTemporarily(_ item: MenuBarItem, alone: Bool) {
        temporary = (item, alone)
        apply()
    }

    func endTemporary() {
        guard temporary != nil else { return }
        temporary = nil
        apply()
    }

    /// Revealed items that aren't drawn on the display the user is working
    /// in, reported through `onOverflow`.
    private func checkOverflow() {
        let visible = MenuBarItems.visible(on: Displays.activeID)
        let drawn = Set(visible.map(\.item.id)).subtracting(MenuBarItems.undrawnIDs(in: visible, on: Displays.active))
        let listed = Set(visible.map(\.item.id))
        let overflow = registry.items.filter { item in
            guard !item.isAccio, staysVisible(item), registry.isRunning(item), !drawn.contains(item.id) else { return false }
            // Apple's items come and go on their own; only count listed ones.
            return item.bundleID != nil || listed.contains(item.id)
        }
        onOverflow?(overflow)
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
        case .shortcut, .reveal: break
        }
    }

    /// Everything that's running, minus what's hidden at the current reveal
    /// level. Allowing apps without items is harmless, and means a newly
    /// launched app shows up straight away.
    ///
    /// `nil` when nothing needs hiding: holding an assertion also hides Focus
    /// and other unlisted Apple items, so don't hold one without a reason.
    private func allowList() -> MenuBarHider.AllowList? {
        let own = Bundle.main.bundleIdentifier ?? MenuBarItem.accio.bundleID!
        if let temporary, temporary.alone {
            let item = temporary.item
            guard item.bundleID != nil || item.systemItem != nil else { return nil }
            return .init(bundleIDs: Set([own, item.bundleID].compactMap { $0 }), systemItems: Set([item.systemItem].compactMap { $0 }))
        }
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
        var systemItems = Set(SystemItem.allCases).subtracting(hiddenSystemItems)
        bundleIDs.insert(own)
        if let temporary {
            // Apple items the API can't name (Focus) only show without an assertion.
            if case .system = temporary.item.owner, temporary.item.systemItem == nil { return nil }
            if let bundleID = temporary.item.bundleID { bundleIDs.insert(bundleID) }
            if let systemItem = temporary.item.systemItem { systemItems.insert(systemItem) }
        }
        return .init(bundleIDs: bundleIDs, systemItems: systemItems)
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

    /// Refresh the item registry in the background, then call `completion`.
    func rescan(then completion: (@MainActor () -> Void)? = nil) {
        guard MenuBarItems.isTrusted else { return }
        scanTask?.cancel()
        let everythingShown = hider.map { !$0.isHiding } ?? true
        scanTask = Task { @MainActor in
            let (visible, apps) = await Task.detached(priority: .utility) {
                (MenuBarItems.visible(includingOwn: true), MenuBarItems.apps())
            }.value
            guard !Task.isCancelled else { return }
            registry.update(visible: visible, everythingShown: everythingShown && !(hider?.isHiding ?? false))
            registry.update(apps: apps)
            completion?()
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
            MainActor.assumeIsolated { VisibilityController.shared.displaysChanged() }
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
        applySoon()
        rescanSoon()
    }

    /// A launched app's items show or hide by the allow-list, which lists
    /// running apps: update it once a burst of launches settles, rather than
    /// swapping the assertion for each app.
    private func applySoon() {
        pendingApply?.cancel()
        pendingApply = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.apply()
        }
    }

    private func reassert() {
        hider?.reassert()
    }

    private func displaysChanged() {
        reassert()
        // MenuBarAgent lays out a new display's bar a moment later.
        Displays.refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            Displays.refresh()
        }
    }

    /// Apps add their items a moment after launching. At login dozens of
    /// apps launch within seconds: one scan, two seconds after the last.
    private func rescanSoon() {
        pendingRescan?.cancel()
        pendingRescan = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.rescan()
        }
    }
}

/// Read-only questions about what the user is doing in the menu bar.
@MainActor
enum MenuBarState {
    /// Whether the pointer is in the menu bar of the display it's on.
    static var isMouseInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        return screen.frame.maxY - point.y <= Displays.menuBarHeight(of: screen) + 1
    }

    /// Whether a menu or popover hangs from a menu bar: some other app's
    /// floating window whose top edge sits just below the bar of its display.
    static var isMenuOpen: Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.map { CGDisplayBounds(Displays.id(of: $0)) }
        return windows.contains { window in
            guard
                let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                window[kCGWindowOwnerName as String] as? String != "Window Server",
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds),
                rect.height > 1
            else { return false }
            guard let display = displays.first(where: { $0.contains(CGPoint(x: rect.midX, y: rect.minY)) }) else { return false }
            let belowBar = rect.minY - display.minY
            return belowBar >= 20 && belowBar <= 60
        }
    }
}

func log(_ message: String) {
    NSLog("%@", message)
}
