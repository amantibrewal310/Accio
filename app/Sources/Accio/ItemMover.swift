import AppKit

/// Moves an item in the real menu bar with a synthesised ⌘-drag, the way a
/// user rearranges items (docs/spikes.md §5, §5b).
///
/// Every item is shown while moving: dragging while only some items are
/// visible makes macOS reshuffle the hidden ones. The drag has to be slow
/// (12 steps × 30 ms) or macOS ignores it, and it moves the pointer, which
/// is put back afterwards.
@MainActor
final class ItemMover: ObservableObject {
    static let shared = ItemMover()

    enum Side { case left, right }

    /// The item being moved, for progress in Settings.
    @Published private(set) var movingID: String?
    /// Why the last move failed, if it did.
    @Published private(set) var failure: String?

    private let controller = VisibilityController.shared

    private init() {}

    /// Put `item` directly to the `side` of `target`.
    func move(_ item: MenuBarItem, to side: Side, of target: MenuBarItem) async {
        guard movingID == nil, item.id != target.id else { return }
        guard MenuBarItems.isTrusted else { return fail("Accio needs Accessibility access to move items.") }
        guard !item.isPinned else { return fail("macOS keeps \(item.name) in place.") }
        movingID = item.id
        failure = nil
        controller.beginMove()
        defer {
            movingID = nil
            controller.endMove()
        }

        for attempt in 1...2 {
            let found = await waitForItems(item, target)
            guard let source = found.source, let destination = found.destination else {
                let missing = found.source == nil ? item : target
                return fail("\(missing.name) isn't in the menu bar right now, so Accio can't move items next to it.")
            }
            if isInPlace(item, side, target) { return }
            if let reason = notDrawnReason(source, destination) { return fail(reason) }
            await drag(from: source.frame, to: side == .left
                ? CGPoint(x: destination.frame.minX + 3, y: destination.frame.midY)
                : CGPoint(x: destination.frame.maxX - 3, y: destination.frame.midY))
            // AX catches up with the move a little later.
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                if isInPlace(item, side, target) { return }
            }
            log("[Mover] \(item.id) not in place after attempt \(attempt)")
        }
        fail("macOS didn't move \(item.name). Try again, or ⌘-drag it in the menu bar.")
    }

    private func fail(_ reason: String) {
        failure = reason
        log("[Mover] \(reason)")
    }

    /// Both items, once every item has faded in and the bar has settled.
    private func waitForItems(_ item: MenuBarItem, _ target: MenuBarItem) async -> (source: VisibleItem?, destination: VisibleItem?) {
        var previous: [CGRect] = []
        var source: VisibleItem?
        var destination: VisibleItem?
        // Up to ~3 s: the fade-in takes about one.
        for _ in 0..<20 {
            let visible = MenuBarItems.visible()
            ItemRegistry.shared.update(visible: visible)
            source = visible.first { $0.item.id == item.id }
            destination = visible.first { $0.item.id == target.id }
            let frames = visible.map(\.frame)
            if source != nil, destination != nil, frames == previous { return (source, destination) }
            previous = frames
            try? await Task.sleep(for: .milliseconds(150))
        }
        return (source, destination)
    }

    private func isInPlace(_ item: MenuBarItem, _ side: Side, _ target: MenuBarItem) -> Bool {
        let visible = MenuBarItems.visible()
        ItemRegistry.shared.update(visible: visible)
        let ids = visible.map(\.item.id)
        guard let index = ids.firstIndex(of: item.id), let targetIndex = ids.firstIndex(of: target.id) else { return false }
        return index == targetIndex + (side == .left ? -1 : 1)
    }

    /// Items that don't fit sit behind the notch or the overflow chevron and
    /// aren't drawn, so they can't be grabbed.
    private func notDrawnReason(_ items: VisibleItem...) -> String? {
        let screen = NSScreen.screens.first
        let notch: CGRect? = screen.flatMap { screen in
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
            return CGRect(x: screen.frame.minX + left.maxX, y: 0, width: right.minX - left.maxX, height: left.height)
        }
        let visible = MenuBarItems.visible()
        for item in items {
            let behindNotch = notch.map { $0.intersects(item.frame) } ?? false
            let stacked = visible.contains { $0.item.id != item.item.id && $0.frame.intersection(item.frame).width > 2 }
            if behindNotch || stacked {
                return "\(item.item.name) doesn't fit in the menu bar right now, so it can't be moved. Quit an app or hide another item first."
            }
        }
        return nil
    }

    private func drag(from frame: CGRect, to end: CGPoint) async {
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let saved = CGEvent(source: nil)?.location
        post(.leftMouseDown, at: start)
        try? await Task.sleep(for: .milliseconds(60))
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            try? await Task.sleep(for: .milliseconds(30))
        }
        post(.leftMouseUp, at: end)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type, mouseCursorPosition: point, mouseButton: .left
        )
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
}
