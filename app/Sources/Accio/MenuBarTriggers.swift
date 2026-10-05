import AppKit

/// Optional ways to show hidden items besides clicking Accio and the hotkey:
/// resting the pointer on empty menu bar space, and swiping or scrolling on
/// the menu bar. Each listens for global mouse events only while enabled.
@MainActor
final class MenuBarTriggers {
    static let shared = MenuBarTriggers()

    /// The pointer rested on empty menu bar space.
    var onHover: (@MainActor () -> Void)?
    /// A swipe or scroll on the menu bar: `true` for down (show), `false` for up (hide).
    var onScroll: (@MainActor (Bool) -> Void)?

    private var hoverMonitor: Any?
    private var scrollMonitor: Any?
    private var dwellTimer: Timer?
    /// Hover shows items once per visit to the menu bar, so items hidden
    /// with a click or a swipe stay hidden until the pointer comes back.
    private var hoverUsed = false
    private var scrollAmount: CGFloat = 0
    private var lastScrollEvent = Date.distantPast
    private var lastScrollAction = Date.distantPast

    private static let dwell: TimeInterval = 0.35

    private init() {}

    func update(hover: Bool, scroll: Bool) {
        if hover, hoverMonitor == nil {
            hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
                MainActor.assumeIsolated { MenuBarTriggers.shared.mouseMoved() }
            }
        } else if !hover, let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
        if scroll, scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { MenuBarTriggers.shared.scrolled(event) }
            }
        } else if !scroll, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: Hover

    /// Cheap on every move: only checks the pointer's height. The empty-space
    /// test (a few AX reads) runs once the pointer has rested.
    private func mouseMoved() {
        guard MenuBarState.isMouseInMenuBar else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            hoverUsed = false
            return
        }
        guard !hoverUsed else { return }
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { _ in
            MainActor.assumeIsolated {
                let triggers = MenuBarTriggers.shared
                triggers.dwellTimer = nil
                guard !triggers.hoverUsed, MenuBarState.isMouseInMenuBar, Self.isOverEmptySpace() else { return }
                triggers.hoverUsed = true
                triggers.onHover?()
            }
        }
    }

    /// Between the frontmost app's menus and the leftmost menu bar item, and
    /// not under the notch, on the menu bar of the display the pointer is on.
    private static func isOverEmptySpace() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        // x is the same in AppKit's and AX's global coordinates.
        let x = point.x
        if let notch = MenuBarItems.notchRect(on: screen), x >= notch.minX, x <= notch.maxX { return false }
        let display = Displays.id(of: screen)
        let itemsStart = MenuBarItems.visible(on: display, includingOwn: true).map(\.frame.minX).min() ?? screen.frame.maxX
        return x > appMenusEnd(on: display) + 4 && x < itemsStart - 4
    }

    /// Right edge of the frontmost app's menus (Apple menu, File, Edit…) on
    /// a display's menu bar; its left edge if they aren't drawn there.
    private static func appMenusEnd(on display: CGDirectDisplayID) -> CGFloat {
        let bounds = CGDisplayBounds(display)
        guard let app = NSWorkspace.shared.frontmostApplication else { return bounds.minX }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let menuBar = AX.element(element, kAXMenuBarAttribute) else { return bounds.minX }
        return AX.children(menuBar).compactMap(AX.frame)
            .filter { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .map(\.maxX).max() ?? bounds.minX
    }

    // MARK: Scroll

    private func scrolled(_ event: NSEvent) {
        guard MenuBarState.isMouseInMenuBar, event.scrollingDeltaY != 0, event.momentumPhase == [] else { return }
        // A new gesture starts the count again.
        if event.phase == .began || Date().timeIntervalSince(lastScrollEvent) > 0.3 { scrollAmount = 0 }
        lastScrollEvent = Date()
        // Fingers moving down, whatever the scroll direction setting.
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        scrollAmount += event.hasPreciseScrollingDeltas ? delta : delta * 10
        guard abs(scrollAmount) > 12, Date().timeIntervalSince(lastScrollAction) > 0.5 else { return }
        lastScrollAction = Date()
        hoverUsed = true
        onScroll?(scrollAmount > 0)
        scrollAmount = 0
    }
}
