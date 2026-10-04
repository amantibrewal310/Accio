import AppKit
import ApplicationServices

/// An app that has at least one item in the menu bar.
struct MenuBarApp: Identifiable, Equatable, Sendable {
    let bundleID: String
    let name: String
    let itemCount: Int

    var id: String { bundleID }
}

/// Finds the running apps that own menu bar items, by asking each app for its
/// `AXExtrasMenuBar`. Unlike MenuBarAgent's tree, this also sees apps whose
/// items are currently hidden. Needs Accessibility.
enum MenuBarApps {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Takes ~100 ms, so call it off the main thread.
    nonisolated static func scan() -> [MenuBarApp] {
        // MenuBarAgent hosts Apple's own items, which are listed as `SystemItem`s.
        let excluded: Set<String?> = [Bundle.main.bundleIdentifier, "com.apple.MenuBarAgent"]
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
            return MenuBarApp(bundleID: bundleID, name: app.localizedName ?? bundleID, itemCount: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func itemCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        // Some apps never answer; don't let one hang the scan.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let extras, CFGetTypeID(extras) == AXUIElementGetTypeID()
        else { return 0 }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(extras as! AXUIElement, kAXChildrenAttribute as CFString, &count) == .success
        else { return 0 }
        return count
    }
}
