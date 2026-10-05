import AppKit

/// Opens an item's menu, whether it's drawn or hidden (docs/spikes.md §4, §4b).
///
/// Most apps' items take an `AXPress` even while hidden: the menu opens at
/// once, hanging from where the item was last drawn on the main display.
/// Some apps (Passwords) accept the press but show nothing while their item
/// is hidden, and Apple's items have no AX actions: those are shown for a
/// moment and clicked, and hidden again once their menu closes. So are all
/// items when the user is on another display, so the menu opens there.
@MainActor
final class ItemOpener {
    static let shared = ItemOpener()

    enum Button: Sendable { case left, right }

    private let controller = VisibilityController.shared
    /// Whether a request is on its way to opening a menu. Once the menu is
    /// open, a request only waits for it to close, and a new one takes over.
    private var isStarting = false
    /// Bumped by every request, so an older one knows it has been replaced.
    private var request = 0
    /// Called with where an item is about to be clicked, and with `nil` once
    /// its menu has closed, so Accio's stand-in icon can step aside.
    var onClickSlot: (@MainActor (CGRect?) -> Void)?

    private init() {}

    func open(_ item: MenuBarItem, button: Button = .left) {
        guard !isStarting else { return }
        isStarting = true
        request += 1
        let request = request
        // A previous request may still be keeping its item shown for a menu
        // the user has moved on from.
        controller.endTemporary()
        onClickSlot?(nil)
        // Where the user is working. A press opens the menu on the main
        // display (apps' items report their place there).
        let screen = Displays.active
        let onMainDisplay = (screen.map(Displays.id(of:)) ?? CGMainDisplayID()) == CGMainDisplayID()
        Task {
            defer { if self.request == request { isStarting = false } }
            if onMainDisplay, let bundleID = item.bundleID, await Self.press(item, of: bundleID, button: button),
               await menuAppears() {
                return
            }
            await clickShowingItem(item, button, on: screen, request: request)
        }
    }

    /// `AXPress` (or `AXShowMenu` for a right-click) on the app's item.
    /// Off the main thread: an app whose item opens an `NSMenu` doesn't
    /// answer until the menu closes.
    private static func press(_ item: MenuBarItem, of bundleID: String, button: Button) async -> Bool {
        // Which of the app's AX items is this one? Drawn items have about
        // the same frame in MenuBarAgent's tree; the others (hidden, or
        // stacked on the overflow chevron) keep their order among the app's
        // other undrawn items.
        let visible = MenuBarItems.visible()
        let undrawn = MenuBarItems.undrawnIDs(in: visible)
        let drawn = visible.filter { $0.item.bundleID == bundleID && !undrawn.contains($0.item.id) }
        let frame = drawn.first { $0.item.id == item.id }?.frame
        let drawnFrames = drawn.map(\.frame)
        let undrawnIDs = ItemRegistry.shared.items
            .filter { $0.bundleID == bundleID && !drawn.map(\.item.id).contains($0.id) }
            .sorted { $0.appIndex < $1.appIndex }
            .map(\.id)
        let undrawnIndex = undrawnIDs.firstIndex(of: item.id)
        return await Task.detached(priority: .userInitiated) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard let extras = AX.element(element, "AXExtrasMenuBar") else { return false }
            let children = AX.children(extras).map { ($0, AX.frame($0) ?? .zero) }.sorted { $0.1.minX < $1.1.minX }
            // The child nearest to `frame`, if it's within a few points.
            func nearest(_ frame: CGRect, in candidates: [(AXUIElement, CGRect)]) -> Int? {
                let best = candidates.indices.min { abs(candidates[$0].1.minX - frame.minX) < abs(candidates[$1].1.minX - frame.minX) }
                return best.flatMap { abs(candidates[$0].1.minX - frame.minX) < 4 ? $0 : nil }
            }
            let target: AXUIElement?
            if let frame {
                target = nearest(frame, in: children).map { children[$0].0 }
            } else if let undrawnIndex {
                var rest = children
                for frame in drawnFrames {
                    if let index = nearest(frame, in: rest) { rest.remove(at: index) }
                }
                target = undrawnIndex < rest.count ? rest[undrawnIndex].0 : nil
            } else {
                target = nil
            }
            guard let target else { return false }
            let action = button == .right && AX.actions(target).contains("AXShowMenu") ? "AXShowMenu" : kAXPressAction
            let result = AXUIElementPerformAction(target, action as CFString)
            log("[Opener] \(action) on \(item.id): \(result.rawValue)")
            // A timeout means the app is busy showing its menu.
            return result == .success || result == .cannotComplete
        }.value
    }

    /// Whether a menu or popover opens within half a second.
    private func menuAppears() async -> Bool {
        for _ in 0..<10 {
            if MenuBarState.isMenuOpen { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return MenuBarState.isMenuOpen
    }

    /// Click the item where it's drawn on `screen`, showing it first if it's
    /// hidden or doesn't fit.
    private func clickShowingItem(_ item: MenuBarItem, _ button: Button, on screen: NSScreen?, request: Int) async {
        var slot = Self.drawnFrame(of: item, on: screen)
        if slot == nil {
            controller.showTemporarily(item, alone: false)
            slot = await waitUntilDrawn(item, on: screen)
            if slot == nil {
                // No room next to the others (notch): show it on its own.
                controller.showTemporarily(item, alone: true)
                slot = await waitUntilDrawn(item, on: screen)
            }
        }
        guard let slot else {
            log("[Opener] \(item.id) didn't appear")
            controller.endTemporary()
            return
        }
        onClickSlot?(slot)
        // Let a stand-in icon over the item fade out of the way.
        try? await Task.sleep(for: .milliseconds(100))
        await Self.bringDownMenuBar(on: screen, above: slot)
        await Self.click(at: CGPoint(x: slot.midX, y: slot.midY), button: button)
        // Keep it shown while its menu is open, unless the user opens
        // another item meanwhile: that request shows its own.
        try? await Task.sleep(for: .milliseconds(600))
        isStarting = false
        while MenuBarState.isMenuOpen, self.request == request {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard self.request == request else { return }
        controller.endTemporary()
        onClickSlot?(nil)
    }

    /// The item's frame once it has faded in and stopped moving; gives up after ~2 s.
    private func waitUntilDrawn(_ item: MenuBarItem, on screen: NSScreen?) async -> CGRect? {
        var previous: CGRect?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            let frame = Self.drawnFrame(of: item, on: screen)
            if let frame, frame == previous { return frame }
            previous = frame
        }
        return nil
    }

    private static func drawnFrame(of item: MenuBarItem, on screen: NSScreen?) -> CGRect? {
        let visible = MenuBarItems.visible(on: screen.map(Displays.id(of:)) ?? CGMainDisplayID())
        guard !MenuBarItems.undrawnIDs(in: visible, on: screen).contains(item.id) else { return nil }
        return visible.first { $0.item.id == item.id }?.frame
    }

    /// In full screen (or with the menu bar set to hide), the bar is away
    /// until the pointer touches the top edge, and a click where the item
    /// would be lands in the app below. Moving the pointer there brings the
    /// bar down; warping it doesn't. The bar is in place after ~300 ms.
    private static func bringDownMenuBar(on screen: NSScreen?, above slot: CGRect) async {
        guard let screen, MenuBarPresence.autoHides(screen), !MenuBarState.isMouseInMenuBar else { return }
        let top = CGPoint(x: slot.midX, y: CGDisplayBounds(Displays.id(of: screen)).minY)
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: top, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func click(at point: CGPoint, button: Button) async {
        let saved = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        let (down, up, mouseButton): (CGEventType, CGEventType, CGMouseButton) = button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)
        CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: mouseButton)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: mouseButton)?
            .post(tap: .cghidEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }
}
