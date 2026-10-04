import AppKit
import ApplicationServices

/// Spike 2b: on macOS 27 status items are no longer separate windows, so try
/// enumerating them through each app's AXExtrasMenuBar instead.
struct AXMenuBarItem {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String?
    /// Global coordinates, top-left origin (AX uses the same space as CG).
    let frame: CGRect
    let title: String?
    let label: String?
    let identifier: String?
    let actions: [String]

    var displayName: String {
        [title, label, identifier].compactMap { $0 }.first { !$0.isEmpty } ?? "-"
    }
}

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as _: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let posValue: AXValue = attribute(element, kAXPositionAttribute),
            let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Status items of one app.
    static func items(of app: NSRunningApplication, timeout: Float = 0.25) -> [AXMenuBarItem] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Some apps never answer; don't let one hang the whole scan.
        AXUIElementSetMessagingTimeout(appElement, timeout)
        guard
            let extras: AXUIElement = attribute(appElement, "AXExtrasMenuBar"),
            let children: [AXUIElement] = attribute(extras, kAXChildrenAttribute)
        else { return [] }
        return children.compactMap { child in
            guard let frame = frame(of: child) else { return nil }
            return AXMenuBarItem(
                element: child,
                pid: app.processIdentifier,
                appName: app.localizedName ?? "?",
                bundleID: app.bundleIdentifier,
                frame: frame,
                title: attribute(child, kAXTitleAttribute),
                label: attribute(child, kAXDescriptionAttribute),
                identifier: attribute(child, kAXIdentifierAttribute),
                actions: actions(of: child)
            )
        }
    }

    /// Status items of every running app, left to right.
    static func allItems() -> [AXMenuBarItem] {
        NSWorkspace.shared.runningApplications
            .flatMap { items(of: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Same as `allItems`, but queries apps concurrently so one slow app
    /// only costs its own timeout.
    static func allItemsParallel() -> [AXMenuBarItem] {
        // XPC helpers (WebContent etc.) never own status items and each one
        // burns the full messaging timeout, so only ask real app bundles.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.pathExtension == "app" }
        let results = UnsafeMutableBufferPointer<[AXMenuBarItem]>.allocate(capacity: apps.count)
        results.initialize(repeating: [])
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            results[i] = items(of: apps[i])
        }
        return results.flatMap { $0 }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func press(_ item: AXMenuBarItem) -> AXError {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    }
}

func printAXTable(_ items: [AXMenuBarItem]) {
    print(pad("#", 3), pad("x", 6), pad("w", 4), pad("pid", 6), pad("app", 22), pad("name", 28), "actions")
    for (i, item) in items.enumerated() {
        print(
            pad(String(i), 3),
            pad(String(Int(item.frame.minX)), 6),
            pad(String(Int(item.frame.width)), 4),
            pad(String(item.pid), 6),
            pad(item.appName, 22),
            pad(item.displayName, 28),
            item.actions.joined(separator: ",")
        )
    }
}
