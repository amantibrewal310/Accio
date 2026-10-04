import AppKit
import CoreGraphics

/// Synthetic mouse events for click forwarding (spike 4) and reordering (spike 5).
enum Synth {
    enum Delivery: String {
        /// Post to the HID event tap. Moves the real cursor; restored afterwards.
        case hid
        /// Post straight to the owning process. Cursor never moves.
        case pid
    }

    static func mouse(
        _ type: CGEventType,
        at point: CGPoint,
        flags: CGEventFlags = [],
        windowID: CGWindowID? = nil
    ) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            return nil
        }
        event.flags = flags
        if let windowID {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        }
        return event
    }

    static func click(_ window: MenuBarWindow, delivery: Delivery) async {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let cursor = CGEvent(source: nil)?.location
        let down = mouse(.leftMouseDown, at: center, windowID: window.windowID)
        let up = mouse(.leftMouseUp, at: center, windowID: window.windowID)
        switch delivery {
        case .hid:
            down?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(30))
            up?.post(tap: .cghidEventTap)
            if let cursor { CGWarpMouseCursorPosition(cursor) }
        case .pid:
            down?.postToPid(window.ownerPID)
            try? await Task.sleep(for: .milliseconds(30))
            up?.postToPid(window.ownerPID)
        }
    }

    /// ⌘-drag `source` so it lands just left of `target`, the same gesture a
    /// user performs by hand. Always goes through the HID tap: the window
    /// server, not the owning app, handles menu bar reordering.
    static func commandDrag(_ source: MenuBarWindow, toLeftOf target: MenuBarWindow, steps: Int) async {
        let start = CGPoint(x: source.frame.midX, y: source.frame.midY)
        let end = CGPoint(x: target.frame.minX + 2, y: target.frame.midY)
        let cursor = CGEvent(source: nil)?.location

        mouse(.leftMouseDown, at: start, flags: .maskCommand, windowID: source.windowID)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        for i in 1...max(steps, 1) {
            let t = CGFloat(i) / CGFloat(max(steps, 1))
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
            mouse(.leftMouseDragged, at: p, flags: .maskCommand)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
        }
        mouse(.leftMouseUp, at: end, flags: .maskCommand)?.post(tap: .cghidEventTap)
        if let cursor { CGWarpMouseCursorPosition(cursor) }
    }
}
