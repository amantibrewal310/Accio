import AppKit
import ApplicationServices

/// One item in the menu bar, as Accio knows it. Hidden items aren't drawn,
/// so an item can be known without being on screen (see `ItemRegistry`).
struct MenuBarItem: Identifiable, Hashable, Sendable {
    enum Owner: Hashable, Sendable {
        case app(bundleID: String)
        /// One of Apple's items hosted by MenuBarAgent, e.g. `com.apple.menuextra.clock`.
        case system(identifier: String)
    }

    /// Stable across launches: the system identifier, or the app's bundle ID
    /// plus the item's index among that app's items (left to right).
    let id: String
    let owner: Owner
    var name: String
    /// What the app calls this item (its accessibility title), when that
    /// says more than the app's name. Tells apart apps' several items.
    var title: String?

    init(id: String, owner: Owner, name: String, title: String? = nil) {
        self.id = id
        self.owner = owner
        self.name = name
        self.title = title
    }

    /// The name, with the item's title for apps with several items
    /// ("Stats – CPU"); `number` stands in when the app gives no title.
    func label(number: Int?) -> String {
        guard let number else { return name }
        guard let title else { return "\(name) \(number)" }
        return title.localizedCaseInsensitiveContains(name) ? title : "\(name) – \(title)"
    }

    var bundleID: String? {
        if case .app(let bundleID) = owner { bundleID } else { nil }
    }

    /// The hiding API's ID for this item; `nil` for third-party items and for
    /// Apple items it can't keep visible (Focus and the like).
    var systemItem: SystemItem? {
        if case .system(let identifier) = owner { SystemItem(menuExtraIdentifier: identifier) } else { nil }
    }

    /// macOS pins these to the right end; they can't be dragged.
    var isPinned: Bool {
        systemItem == .clock || systemItem == .controlCenter
    }

    static func appItemID(_ bundleID: String, index: Int) -> String {
        "\(bundleID)#\(index)"
    }

    /// Accio's own status item. It isn't in any section: it's the line
    /// between hidden items (left of it) and shown ones (right of it).
    static let accio: MenuBarItem = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.accio.app"
        return MenuBarItem(id: appItemID(bundleID, index: 0), owner: .app(bundleID: bundleID), name: "Accio")
    }()

    var isAccio: Bool { id == Self.accio.id }

    /// The item's place among its app's items, left to right.
    var appIndex: Int {
        id.split(separator: "#").last.flatMap { Int($0) } ?? 0
    }

    /// SF Symbol standing in for Apple's items, which have no app icon.
    var symbolName: String? {
        guard case .system(let identifier) = owner else { return nil }
        return systemItem?.symbol ?? (identifier.hasSuffix("focusmode") ? "moon.fill" : "menubar.rectangle")
    }
}

/// An item that is drawn in the menu bar right now.
struct VisibleItem: Sendable {
    let item: MenuBarItem
    /// Global coordinates, top-left origin.
    let frame: CGRect
}

/// An app that has at least one item in the menu bar.
struct MenuBarApp: Identifiable, Equatable, Sendable {
    let bundleID: String
    let name: String
    /// Each item's title, left to right (see `MenuBarItem.title`).
    let itemTitles: [String?]

    var itemCount: Int { itemTitles.count }

    var id: String { bundleID }
}

/// Reads the menu bar through Accessibility (docs/spikes.md §2b, §2c).
enum MenuBarItems {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static let agentBundleID = "com.apple.MenuBarAgent"

    /// Whether a slot frame belongs to `display`'s menu bar. Each display
    /// has its own bar, and displays side by side all have theirs at the top.
    private static func isInBar(_ frame: CGRect, of display: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(display)
        return frame.width > 0 && frame.minY >= bounds.minY && frame.minY < bounds.minY + 4
            && frame.midX >= bounds.minX && frame.midX < bounds.maxX
    }

    /// Items drawn on a display's menu bar (the main display's by default),
    /// left to right, from MenuBarAgent's AX tree: one slot per item, whose
    /// first child belongs to the item's app. Items hidden by Accio aren't
    /// listed. Accio's own item is left out unless `includingOwn`. Takes a
    /// few milliseconds.
    static func visible(on display: CGDirectDisplayID = CGMainDisplayID(), includingOwn: Bool = false) -> [VisibleItem] {
        guard
            isTrusted,
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first
        else { return [] }
        let agentPID = agent.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let app = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(app, 0.1)

        // The agent keeps several windows that list the same slots.
        var seen = Set<String>()
        var slots: [(frame: CGRect, owner: AXUIElement, pid: pid_t)] = []
        for window in AX.children(app, kAXWindowsAttribute) {
            for slot in AX.children(window) {
                guard
                    let frame = AX.frame(slot), isInBar(frame, of: display),
                    // The overflow chevron is the slot without a child.
                    let owner = AX.children(slot).first
                else { continue }
                let pid = AX.pid(owner)
                guard includingOwn || pid != ownPID, seen.insert("\(pid):\(Int(frame.minX))").inserted else { continue }
                slots.append((frame, owner, pid))
            }
        }
        slots.sort { $0.frame.minX < $1.frame.minX }

        var appIndex: [String: Int] = [:]
        var names: [pid_t: String] = [:]
        return slots.compactMap { slot in
            if slot.pid == ownPID { return VisibleItem(item: .accio, frame: slot.frame) }
            if slot.pid == agentPID {
                // Apple's items: slot → hosting view → the item, which has the identifier.
                var element = slot.owner
                while AX.string(element, kAXIdentifierAttribute) == nil, let child = AX.children(element).first {
                    element = child
                }
                guard let identifier = AX.string(element, kAXIdentifierAttribute) else { return nil }
                let name = SystemItem(menuExtraIdentifier: identifier)?.title
                    ?? AX.string(element, kAXDescriptionAttribute)
                    ?? identifier.components(separatedBy: ".").last!.capitalized
                return VisibleItem(
                    item: MenuBarItem(id: identifier, owner: .system(identifier: identifier), name: name),
                    frame: slot.frame
                )
            }
            guard let running = NSRunningApplication(processIdentifier: slot.pid),
                  let bundleID = running.bundleIdentifier
            else { return nil }
            let index = appIndex[bundleID, default: 0]
            appIndex[bundleID] = index + 1
            let name = names[slot.pid] ?? displayName(of: running)
            names[slot.pid] = name
            return VisibleItem(
                item: MenuBarItem(id: MenuBarItem.appItemID(bundleID, index: index), owner: .app(bundleID: bundleID), name: name),
                frame: slot.frame
            )
        }
    }

    /// The notch on a display (the main one by default), in global top-left
    /// coordinates.
    @MainActor
    static func notchRect(on screen: NSScreen? = NSScreen.screens.first) -> CGRect? {
        guard let screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let top = CGDisplayBounds(Displays.id(of: screen)).minY
        return CGRect(x: screen.frame.minX + left.maxX, y: top, width: right.minX - left.maxX, height: left.height)
    }

    /// Listed items that aren't really drawn: behind the notch, or stacked
    /// on the overflow chevron with others because they don't fit. `visible`
    /// must come from `screen`'s menu bar.
    @MainActor
    static func undrawnIDs(in visible: [VisibleItem], on screen: NSScreen? = NSScreen.screens.first) -> Set<String> {
        let notch = notchRect(on: screen)
        var ids = Set<String>()
        for item in visible {
            let behindNotch = notch.map { $0.intersects(item.frame) } ?? false
            let stacked = visible.contains { $0.item.id != item.item.id && $0.frame.intersection(item.frame).width > 2 }
            if behindNotch || stacked { ids.insert(item.item.id) }
        }
        return ids
    }

    /// Where Accio's own status item is drawn on a display, while it's drawn.
    static func ownItemFrame(on display: CGDirectDisplayID = CGMainDisplayID()) -> CGRect? {
        guard
            isTrusted,
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        for window in AX.children(app, kAXWindowsAttribute) {
            for slot in AX.children(window) {
                guard let owner = AX.children(slot).first, AX.pid(owner) == ownPID,
                      let frame = AX.frame(slot), isInBar(frame, of: display)
                else { continue }
                return frame
            }
        }
        return nil
    }

    /// Every display's menu bar, as MenuBarAgent lays it out (one window per
    /// bar, some repeated).
    static func barFrames() -> [CGRect] {
        guard
            isTrusted,
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first
        else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return AX.children(app, kAXWindowsAttribute).compactMap(AX.frame)
    }

    /// Running apps that own menu bar items, by asking each app for its
    /// `AXExtrasMenuBar`. Unlike `visible()`, this also sees apps whose items
    /// are hidden. Takes ~100 ms, so call it off the main thread.
    static func apps() -> [MenuBarApp] {
        guard isTrusted else { return [] }
        // MenuBarAgent hosts Apple's own items, which `visible()` reports.
        let excluded: Set<String?> = [Bundle.main.bundleIdentifier, agentBundleID]
        // XPC helpers (WebContent etc.) never own items and each one burns the
        // full messaging timeout, so only ask real app bundles.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.pathExtension == "app" && $0.bundleIdentifier != nil && !excluded.contains($0.bundleIdentifier)
        }
        nonisolated(unsafe) let titles = UnsafeMutableBufferPointer<[String?]>.allocate(capacity: apps.count)
        titles.initialize(repeating: [])
        defer { titles.deallocate() }
        // One slow app then only costs its own timeout.
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            titles[i] = itemTitles(of: apps[i].processIdentifier)
        }
        return zip(apps, titles).compactMap { app, titles in
            guard !titles.isEmpty, let bundleID = app.bundleIdentifier else { return nil }
            let name = displayName(of: app)
            // A title that only repeats the app's name says nothing.
            let useful = titles.map { $0.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 } }
            return MenuBarApp(bundleID: bundleID, name: name, itemTitles: useful)
        }
    }

    /// Helpers inside another app (Passwords.app/…/PasswordsMenuBarExtra.app)
    /// go by the outer app's name.
    static func displayName(of app: NSRunningApplication) -> String {
        if let path = app.bundleURL?.path, let range = path.range(of: ".app/Contents/") {
            return FileManager.default.displayName(atPath: String(path[..<range.lowerBound]) + ".app")
                .replacingOccurrences(of: ".app", with: "")
        }
        return app.localizedName ?? app.bundleIdentifier ?? "?"
    }

    /// The app's items, left to right (hidden ones keep the place they were
    /// last drawn at), with whatever the app calls each: its accessibility
    /// description, title or help tag.
    private static func itemTitles(of pid: pid_t) -> [String?] {
        let app = AXUIElementCreateApplication(pid)
        // Some apps never answer; don't let one hang the scan.
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let extras = AX.element(app, "AXExtrasMenuBar") else { return [] }
        return AX.children(extras)
            .map { (AX.frame($0)?.minX ?? 0, $0) }
            .sorted { $0.0 < $1.0 }
            .map { _, item in
                [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].lazy
                    .compactMap { AX.string(item, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
            }
    }
}

/// Small typed wrappers around the AXUIElement C API.
enum AX {
    static func children(_ element: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String, !string.isEmpty
        else { return nil }
        return string
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size,
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func pid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}

/// Calls `onChange` soon after MenuBarAgent's items appear, disappear, move
/// or resize, through AX notifications (needs Accessibility). Bursts are
/// coalesced into one call.
@MainActor
final class MenuBarObserver {
    private let onChange: @MainActor () -> Void
    private var observer: AXObserver?
    private var agentPID: pid_t = 0
    private var isPending = false

    private static let appNotifications = [
        kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification,
    ]
    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXValueChangedNotification,
    ]

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    var isRunning: Bool { observer != nil }

    /// Starts observing, or re-attaches if MenuBarAgent was restarted.
    func start() {
        guard
            MenuBarItems.isTrusted,
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return stop() }
        guard observer == nil || agent.processIdentifier != agentPID else { return }
        stop()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let this = Unmanaged<MenuBarObserver>.fromOpaque(refcon).takeUnretainedValue()
            let windowAppeared = notification as String == kAXCreatedNotification
            MainActor.assumeIsolated {
                if windowAppeared { this.observeWindows() }
                this.changed()
            }
        }
        guard AXObserverCreate(agent.processIdentifier, callback, &observer) == .success, let observer else { return }
        self.observer = observer
        agentPID = agent.processIdentifier
        let app = AXUIElementCreateApplication(agentPID)
        for name in Self.appNotifications { add(name, to: app) }
        observeWindows()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    /// Item frames are reported on the agent's windows, which come and go.
    /// Adding a window twice is harmless.
    private func observeWindows() {
        let app = AXUIElementCreateApplication(agentPID)
        for window in AX.children(app, kAXWindowsAttribute) {
            for name in Self.windowNotifications { add(name, to: window) }
        }
    }

    private func add(_ name: String, to element: AXUIElement) {
        guard let observer else { return }
        AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    private func changed() {
        guard !isPending else { return }
        isPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            self.isPending = false
            if self.observer != nil { self.onChange() }
        }
    }
}
