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
    /// While `tidy()` arranges the whole bar.
    @Published private(set) var isTidying = false

    private let controller = VisibilityController.shared

    private init() {}

    /// Put `item` directly to the `side` of `target`.
    func move(_ item: MenuBarItem, to side: Side, of target: MenuBarItem) async {
        guard movingID == nil, item.id != target.id else { return }
        guard MenuBarItems.isTrusted else { return fail("Accio needs Accessibility access to move items.") }
        guard !item.isPinned else { return fail("macOS keeps \(item.name) in place.") }
        failure = nil
        controller.beginMove()
        defer {
            movingID = nil
            controller.endMove()
        }
        _ = await perform(item, side, target)
    }

    /// Put hidden items left of Accio's own item and shown ones right of it,
    /// so Accio's icon stays where it is when they show and hide. With
    /// `item`, only that item is moved, if it's on the wrong side.
    func tidy(only item: MenuBarItem? = nil) async {
        guard movingID == nil else { return }
        guard MenuBarItems.isTrusted else { return fail("Accio needs Accessibility access to move items.") }
        failure = nil
        isTidying = item == nil
        controller.beginMove()
        defer {
            movingID = nil
            isTidying = false
            controller.endMove()
        }
        // Each step moves one item; a full tidy rarely needs more than a few.
        for _ in 0..<24 {
            let visible = await waitForStableBar()
            guard let step = Self.nextTidyStep(visible, only: item) else { return }
            guard await perform(step.item, step.side, step.target) else { return }
        }
    }

    /// The next move that brings the bar closer to tidy, or `nil` once it is.
    private static func nextTidyStep(_ visible: [VisibleItem], only: MenuBarItem?) -> (item: MenuBarItem, side: Side, target: MenuBarItem)? {
        let order = visible.map(\.item)
        guard let accioIndex = order.firstIndex(where: \.isAccio) else { return nil }
        let preferences = Preferences.shared
        let others = order.filter { !$0.isAccio }
        let isShown = others.map { preferences.section(of: $0.owner) == .shown }
        let accio = order[accioIndex]

        if let only {
            guard let index = others.firstIndex(where: { $0.id == only.id }) else { return nil }
            let isLeft = index < accioIndex
            if isShown[index] == isLeft { return (only, isShown[index] ? .right : .left, accio) }
            return nil
        }

        // Where Accio goes: the spot that leaves the fewest items to move
        // (moving Accio itself counts as one).
        let current = accioIndex
        func cost(_ boundary: Int) -> Int {
            isShown[..<boundary].filter { $0 }.count + isShown[boundary...].filter { !$0 }.count + (boundary == current ? 0 : 1)
        }
        let best = (0...others.count).min { (cost($0), $0 == current ? 0 : 1) < (cost($1), $1 == current ? 0 : 1) }!
        if best != current {
            return best < others.count ? (accio, .left, others[best]) : (accio, .right, others[others.count - 1])
        }
        // Hidden items to Accio's left, in order; shown ones to its right, from the right.
        if let index = isShown.indices.first(where: { $0 >= current && !isShown[$0] }) {
            return (others[index], .left, accio)
        }
        if let index = isShown.indices.last(where: { $0 < current && isShown[$0] }) {
            return (others[index], .right, accio)
        }
        return nil
    }

    /// One verified move, retried once. Assumes every item is shown.
    private func perform(_ item: MenuBarItem, _ side: Side, _ target: MenuBarItem) async -> Bool {
        movingID = item.id
        for attempt in 1...2 {
            let found = await waitForItems(item, target)
            guard let source = found.source, let destination = found.destination else {
                let missing = found.source == nil ? item : target
                fail("\(missing.name) isn't in the menu bar right now, so Accio can't move items next to it.")
                return false
            }
            if isInPlace(item, side, target) { return true }
            if let reason = notDrawnReason(source, destination) {
                fail(reason)
                return false
            }
            await drag(from: source.frame, to: side == .left
                ? CGPoint(x: destination.frame.minX + 3, y: destination.frame.midY)
                : CGPoint(x: destination.frame.maxX - 3, y: destination.frame.midY))
            // AX catches up with the move a little later.
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                if isInPlace(item, side, target) { return true }
            }
            log("[Mover] \(item.id) not in place after attempt \(attempt)")
        }
        fail("macOS didn't move \(item.name). Try again, or ⌘-drag it in the menu bar.")
        return false
    }

    private func fail(_ reason: String) {
        failure = reason
        log("[Mover] \(reason)")
    }

    /// Both items, once every item has faded in and the bar has settled.
    private func waitForItems(_ item: MenuBarItem, _ target: MenuBarItem) async -> (source: VisibleItem?, destination: VisibleItem?) {
        let visible = await waitForStableBar { visible in
            visible.contains { $0.item.id == item.id } && visible.contains { $0.item.id == target.id }
        }
        return (visible.first { $0.item.id == item.id }, visible.first { $0.item.id == target.id })
    }

    /// What's drawn, including Accio, once nothing has moved for 150 ms
    /// (and `isReady`); gives up after ~3 s. The fade-in takes about one.
    private func waitForStableBar(until isReady: ([VisibleItem]) -> Bool = { _ in true }) async -> [VisibleItem] {
        var previous: [CGRect] = []
        var visible: [VisibleItem] = []
        for _ in 0..<20 {
            visible = MenuBarItems.visible(includingOwn: true)
            ItemRegistry.shared.update(visible: visible, everythingShown: true)
            let frames = visible.map(\.frame)
            if frames == previous, isReady(visible) { return visible }
            previous = frames
            try? await Task.sleep(for: .milliseconds(150))
        }
        return visible
    }

    private func isInPlace(_ item: MenuBarItem, _ side: Side, _ target: MenuBarItem) -> Bool {
        let visible = MenuBarItems.visible(includingOwn: true)
        ItemRegistry.shared.update(visible: visible)
        let ids = visible.map(\.item.id)
        guard let index = ids.firstIndex(of: item.id), let targetIndex = ids.firstIndex(of: target.id) else { return false }
        return index == targetIndex + (side == .left ? -1 : 1)
    }

    /// Items that don't fit sit behind the notch or the overflow chevron and
    /// aren't drawn, so they can't be grabbed.
    private func notDrawnReason(_ items: VisibleItem...) -> String? {
        let undrawn = MenuBarItems.undrawnIDs(in: MenuBarItems.visible(includingOwn: true))
        guard let item = items.first(where: { undrawn.contains($0.item.id) }) else { return nil }
        return "\(item.item.name) doesn't fit in the menu bar right now, so it can't be moved. Quit an app or hide another item first."
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
