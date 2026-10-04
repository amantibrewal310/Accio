import AppKit

/// The Bar: a panel hanging below the menu bar, under Accio's icon, with
/// items that aren't in the menu bar (hidden ones, or ones that don't fit
/// next to the notch). Clicking one opens its menu (`ItemOpener`).
///
/// Hidden items aren't drawn on macOS 27, so they can't be captured: the Bar
/// shows app icons and SF Symbols, like the layout editor.
@MainActor
final class BarController {
    static let shared = BarController()

    enum Content: Equatable {
        /// Hidden items, and with `all` the Always Hidden ones too.
        case hidden(all: Bool)
        /// Revealed items that don't fit in the menu bar.
        case overflow([MenuBarItem])
    }

    private(set) var content: Content?
    var isShown: Bool { content != nil }
    /// Called when the Bar opens or closes.
    var onChange: (@MainActor (Bool) -> Void)?
    /// Accio's icon in global Cocoa coordinates, to hang the Bar from.
    var anchor: (@MainActor () -> NSRect?)?

    private let panel = BarPanel()
    private var clickMonitor: Any?
    private var closeTimer: Timer?
    private let registry = ItemRegistry.shared
    private let preferences = Preferences.shared

    private init() {
        panel.onActivate = { [weak self] item, button in self?.activate(item, button) }
        panel.onCancel = { [weak self] in self?.close() }
    }

    func toggle(all: Bool) {
        if case .hidden(let shownAll) = content, shownAll || !all {
            close()
        } else {
            show(.hidden(all: all))
        }
    }

    func show(_ content: Content) {
        var items = items(for: content)
        if case .overflow = content, items.isEmpty { return closeOverflow() }
        // Hidden items first, then Always Hidden ones, with a line between.
        var groups: [Int] = []
        if case .hidden(all: true) = content {
            let hidden = items.filter { preferences.section(of: $0.owner) != .alwaysHidden }
            let alwaysHidden = items.filter { preferences.section(of: $0.owner) == .alwaysHidden }
            items = hidden + alwaysHidden
            if !hidden.isEmpty, !alwaysHidden.isEmpty { groups = [hidden.count] }
        }
        let wasShown = isShown
        self.content = content
        panel.setItems(items, groups: groups)
        panel.present(below: anchor?(), animated: !wasShown)
        if !wasShown {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { BarController.shared.close() }
            }
            onChange?(true)
        }
        scheduleClose()
    }

    func close(animated: Bool = true) {
        guard isShown else { return }
        content = nil
        closeTimer?.invalidate()
        closeTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.dismiss(animated: animated)
        onChange?(false)
    }

    /// Close the Bar if it only shows items that don't fit (they're hidden again).
    func closeOverflow() {
        if case .overflow = content { close() }
    }

    private func activate(_ item: MenuBarItem, _ button: ItemOpener.Button) {
        // Out of the way of the item's menu.
        close(animated: false)
        ItemOpener.shared.open(item, button: button)
    }

    /// Close after the rehide delay, unless the pointer is on the Bar.
    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = nil
        let seconds = TimeInterval(preferences.rehideDelay)
        guard seconds > 0 else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                let bar = BarController.shared
                if bar.panel.containsMouse { bar.scheduleClose() } else { bar.close() }
            }
        }
        closeTimer?.tolerance = 0.2
    }

    // MARK: Contents

    private func items(for content: Content) -> [MenuBarItem] {
        switch content {
        case .overflow(let items): return items
        case .hidden(let all):
            // Plus shown items that don't fit in the menu bar right now.
            let visible = MenuBarItems.visible()
            let undrawn = MenuBarItems.undrawnIDs(in: visible)
            return registry.items.filter { item in
                guard !item.isAccio, registry.isPresent(item) else { return false }
                switch preferences.section(of: item.owner) {
                case .hidden: return true
                case .alwaysHidden: return all
                case .shown: return undrawn.contains(item.id)
                }
            }
        }
    }
}

/// The panel itself: a rounded, translucent strip like a menu.
@MainActor
private final class BarPanel: NSPanel {
    var onActivate: ((MenuBarItem, ItemOpener.Button) -> Void)?
    var onCancel: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing is hidden")
    private var buttons: [BarItemButton] = []
    private var focusedIndex: Int? { didSet { updateFocus() } }

    private static let cornerRadius: CGFloat = 10
    private static let gapBelowMenuBar: CGFloat = 5

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityLabel("Accio Bar")

        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.mask(radius: Self.cornerRadius)
        contentView = effect

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .menuFont(ofSize: 0)
    }

    // A non-activating panel can still take keys (Esc, arrows) without
    // bringing Accio forward.
    override var canBecomeKey: Bool { true }

    var containsMouse: Bool { isVisible && frame.contains(NSEvent.mouseLocation) }

    func setItems(_ items: [MenuBarItem], groups: [Int]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = items.map { item in
            let button = BarItemButton(item: item)
            button.onActivate = { [weak self] button in self?.onActivate?(item, button) }
            return button
        }
        if buttons.isEmpty {
            stack.addArrangedSubview(emptyLabel)
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        } else {
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
            for (index, button) in buttons.enumerated() {
                if groups.contains(index) { stack.addArrangedSubview(Self.separator()) }
                stack.addArrangedSubview(button)
            }
        }
        focusedIndex = nil
        setContentSize(stack.fittingSize)
    }

    /// Hang below `anchor` (Accio's icon), right edges aligned, on screen.
    func present(below anchor: NSRect?, animated: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        let menuBarHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let size = frame.size
        let anchorMaxX = anchor?.maxX ?? (screen.frame.midX + size.width / 2)
        let x = min(max(anchorMaxX - size.width, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)
        let y = screen.frame.maxY - menuBarHeight - Self.gapBelowMenuBar - size.height
        let target = NSRect(x: x.rounded(), y: y, width: size.width, height: size.height)

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(target, display: true)
            alphaValue = 1
            makeKeyAndOrderFront(nil)
            return
        }
        // Drop in from just under the menu bar, like a menu.
        setFrame(target.offsetBy(dx: 0, dy: 6), display: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                // Shown again in the meantime?
                if self.alphaValue == 0 { self.orderOut(nil) }
            }
        }
    }

    // MARK: Keyboard

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard !buttons.isEmpty else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 123: // ←
            focusedIndex = max((focusedIndex ?? buttons.count) - 1, 0)
        case 124: // →
            focusedIndex = min((focusedIndex ?? -1) + 1, buttons.count - 1)
        case 36, 76, 49: // Return, Enter, Space
            if let focusedIndex { buttons[focusedIndex].onActivate?(.left) }
        default:
            super.keyDown(with: event)
        }
    }

    private func updateFocus() {
        for (index, button) in buttons.enumerated() { button.isFocused = index == focusedIndex }
    }

    // MARK: Drawing helpers

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let wrapper = NSStackView(views: [line])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        return wrapper
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One item in the Bar: its app's icon (or a symbol for Apple's items),
/// highlighted on hover like a menu bar item.
@MainActor
private final class BarItemButton: NSView {
    let item: MenuBarItem
    var onActivate: ((ItemOpener.Button) -> Void)?
    var isFocused = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private let image: NSImage

    private static let size = NSSize(width: 32, height: 26)

    init(item: MenuBarItem) {
        self.item = item
        if let symbol = item.symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.name)?
                .withSymbolConfiguration(config) ?? NSImage()
            image.isTemplate = true
        } else {
            image = AppIcons.icon(for: item.bundleID ?? "")
        }
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = item.name
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return onActivate?(.right) ?? () }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?(.left) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?(.right)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed || isHovered || isFocused {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let side: CGFloat = item.symbolName == nil ? 20 : min(image.size.height, 18)
        let size = item.symbolName == nil ? NSSize(width: side, height: side) : image.size
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height).integral
        if image.isTemplate {
            let tinted = NSImage(size: size, flipped: false) { [image] r in
                image.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        } else {
            image.draw(in: rect)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { item.name }
    override func accessibilityPerformPress() -> Bool { onActivate?(.left); return true }
    override func accessibilityPerformShowMenu() -> Bool { onActivate?(.right); return true }
}
