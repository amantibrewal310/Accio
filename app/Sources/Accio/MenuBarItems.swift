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
    let itemCount: Int

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

    /// Items drawn on the main display's menu bar, left to right, from
    /// MenuBarAgent's AX tree: one slot per item, whose first child belongs to
    /// the item's app. Items hidden by Accio aren't listed. Accio's own item
    /// is left out. Takes a few milliseconds.
    static func visible() -> [VisibleItem] {
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
                    let frame = AX.frame(slot), frame.width > 0, frame.minY < 4,
                    // The overflow chevron is the slot without a child.
                    let owner = AX.children(slot).first
                else { continue }
                let pid = AX.pid(owner)
                guard pid != ownPID, seen.insert("\(pid):\(Int(frame.minX))").inserted else { continue }
                slots.append((frame, owner, pid))
            }
        }
        slots.sort { $0.frame.minX < $1.frame.minX }

        var appIndex: [String: Int] = [:]
        var names: [pid_t: String] = [:]
        return slots.compactMap { slot in
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

    /// Where Accio's own status item is drawn, while it's drawn.
    static func ownItemFrame() -> CGRect? {
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
                      let frame = AX.frame(slot), frame.width > 0, frame.minY < 4
                else { continue }
                return frame
            }
        }
        return nil
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
        nonisolated(unsafe) let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: apps.count)
        counts.initialize(repeating: 0)
        defer { counts.deallocate() }
        // One slow app then only costs its own timeout.
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            counts[i] = itemCount(of: apps[i].processIdentifier)
        }
        return zip(apps, counts).compactMap { app, count in
            guard count > 0, let bundleID = app.bundleIdentifier else { return nil }
            return MenuBarApp(bundleID: bundleID, name: displayName(of: app), itemCount: count)
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

    private static func itemCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        // Some apps never answer; don't let one hang the scan.
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let extras = AX.element(app, "AXExtrasMenuBar") else { return 0 }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(extras, kAXChildrenAttribute as CFString, &count) == .success
        else { return 0 }
        return count
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
