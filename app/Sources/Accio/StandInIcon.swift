import AppKit
import ImageIO

/// Accio's icon for builds whose own status item gets hidden too (no team
/// signature, docs/spikes.md §1d): a small window drawn in the menu bar
/// where the real item would be. The assertion only hides status items, so
/// this stays put. Shown only while hiding.
@MainActor
final class StandInIcon {
    private let panel: NSPanel
    private let button: StandInButton
    private var refreshTimer: Timer?
    /// Follows the bar as items fade, appear late (Display) or change width.
    private lazy var barObserver = MenuBarObserver { [weak self] in self?.reposition(animated: true) }

    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onMenu: ((NSView) -> Void)?
    /// Whether an item stays drawn while hiding, so the icon can go straight
    /// to where the bar will settle instead of following the fade.
    var staysVisible: ((MenuBarItem) -> Bool)?
    /// Bumped on every show/hide, so a finished animation doesn't act on a newer state.
    private var generation = 0
    /// Where the real status item was last drawn, so the icon can hand over
    /// to it there when hiding stops.
    private var ownItemFrame: CGRect?
    /// While the icon glides between the real item's place and its own.
    private var isGliding = false
    /// The bar changed during a glide; catch up once it ends.
    private var needsReposition = false

    /// Matches a square status item on a notched display.
    private static let width: CGFloat = 38

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Not on full-screen spaces, where the menu bar is hidden.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        button = StandInButton()
        button.setAccessibilityLabel("Accio")
        panel.contentView = button
        button.onClick = { [weak self] flags in self?.onClick?(flags) }
        button.onMenu = { [weak self] in
            guard let self else { return }
            self.onMenu?(self.button)
        }
    }

    var image: NSImage? {
        get { button.image }
        set { button.image = newValue }
    }

    func setVisible(_ visible: Bool, image: NSImage?) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        barObserver.stop()
        generation += 1
        let generation = generation
        guard visible else {
            // Glide to where the real status item fades back in, then leave
            // it there, so it looks like one icon moving with the bar.
            guard panel.isVisible else { return }
            if let own = ownItemFrame {
                // Head for where it was last; correct once it's drawn.
                glide(to: own.minX) { [weak self] in self?.handOver(generation, until: .now + .seconds(1)) }
            } else {
                handOver(generation, until: .now + .seconds(1))
            }
            return
        }
        button.image = image
        let wasVisible = panel.isVisible && panel.alphaValue == 1
        if !wasVisible, let own = MenuBarItems.ownItemFrame() {
            // Hiding starts: take over from the real item where it is drawn,
            // then glide along as the hidden items fade out.
            ownItemFrame = own
            panel.alphaValue = 1
            panel.setFrame(frame(atX: own.minX), display: true)
            panel.orderFrontRegardless()
            if let target = targetX() {
                glide(to: target) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.reposition()
                }
            }
        } else {
            reposition()
            if !wasVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                fade(to: 1)
            }
        }
        barObserver.start()
        // A backstop for changes the observer misses, and for a restarted
        // MenuBarAgent (start() re-attaches then).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.barObserver.start()
                self?.reposition()
            }
        }
        refreshTimer?.tolerance = 2
    }

    /// Once the real status item is drawn again, glide onto it and leave it
    /// there. It reappears within a few hundred ms; give up after `deadline`.
    private func handOver(_ generation: Int, until deadline: ContinuousClock.Instant) {
        guard self.generation == generation else { return }
        let done: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
        if let own = MenuBarItems.ownItemFrame() {
            ownItemFrame = own
            if abs(panel.frame.minX - own.minX) <= 1 {
                // Already on it: stay on top until it has faded in, or it blinks.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    done()
                }
            } else {
                glide(to: own.minX, completion: done)
            }
        } else if ContinuousClock.now >= deadline {
            fade(to: 0, completion: done)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.handOver(generation, until: deadline)
            }
        }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Slide to `x` at about the pace of the system's item fade.
    private func glide(to x: CGFloat, completion: @escaping @MainActor () -> Void) {
        let target = frame(atX: x)
        guard !Self.reduceMotion, abs(panel.frame.minX - x) > 1 else {
            panel.setFrame(target, display: true)
            return completion()
        }
        isGliding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            // Quick start, soft landing, like the system's own item moves.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.isGliding = false
                completion()
                if self.needsReposition {
                    self.needsReposition = false
                    self.reposition(animated: true)
                }
            }
        }
    }

    /// Matches the speed of the system's item fade.
    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        guard !Self.reduceMotion else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    /// Follow the bar; `animated` slides along with items that move.
    private func reposition(animated: Bool = false) {
        guard !isGliding else {
            needsReposition = true
            return
        }
        guard let x = targetX() else { return }
        if let screen = NSScreen.screens.first { button.tint = MenuBarTint.glyphColor(on: screen) }
        let frame = frame(atX: x)
        guard panel.frame != frame else { return }
        if animated, panel.isVisible {
            glide(to: x) {}
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Where the real item would be once the bar settles, but never behind
    /// the notch. Without Accessibility, just right of the notch (or the
    /// middle): shown items are right-aligned, so that spot is usually free.
    private func targetX() -> CGFloat? {
        guard let screen = NSScreen.screens.first else { return nil }
        let notchRight = screen.auxiliaryTopRightArea.map { screen.frame.minX + $0.minX }
        var x = settledOwnMaxX().map { $0 - Self.width }
            ?? notchRight.map { $0 + 4 } ?? screen.frame.midX
        if let notchRight { x = max(x, notchRight) }
        return x
    }

    private func frame(atX x: CGFloat) -> NSRect {
        guard let screen = NSScreen.screens.first else { return panel.frame }
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return NSRect(x: x, y: screen.frame.maxY - height, width: Self.width, height: height)
    }
}

extension StandInIcon {
    /// Right edge of the real item once the bar has settled: just left of
    /// the first item to its right that stays drawn. Items are packed
    /// against the right end, so add up the room each staying item right of
    /// Accio takes (its distance to its right neighbour: Apple's items have
    /// about 8 pt of padding on each side, apps' items none). Right after
    /// hiding starts, the hidden items are still drawn and would put the
    /// icon too far left.
    private func settledOwnMaxX() -> CGFloat? {
        let visible = MenuBarItems.visible()
        guard let right = visible.map(\.frame.maxX).max() else { return nil }
        // Accio's place among the items, from when it was last drawn.
        let order = ItemRegistry.shared.items.map(\.id)
        let leftOfAccio = order.firstIndex(of: MenuBarItem.accio.id).map { Set(order[..<$0]) } ?? []
        var x = right
        var leftPadding: CGFloat = 0
        for (index, item) in visible.enumerated().reversed() where staysVisible?(item.item) ?? true {
            if leftOfAccio.contains(item.item.id) { break }
            let next = index + 1 < visible.count ? visible[index + 1].frame.minX : item.frame.maxX
            let advance = next - item.frame.minX
            x -= advance
            leftPadding = item.item.bundleID == nil ? ((advance - item.frame.width) / 2).rounded(.down) : 0
        }
        return x - leftPadding
    }
}

/// Draws the icon like a status item, with the pressed highlight.
private final class StandInButton: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var tint: NSColor = .labelColor { didSet { if tint != oldValue { needsDisplay = true } } }
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onMenu: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // Clicks fall through fully transparent pixels of a clear window, so
        // cover the whole button with an invisible fill.
        NSColor.black.withAlphaComponent(0.005).setFill()
        bounds.fill()
        if isPressed {
            tint.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        guard let image else { return }
        let size = image.size
        let rect = NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        ).integral
        // Template images take the menu bar's text colour.
        let tint = tint
        let tinted = NSImage(size: size, flipped: false) { r in
            image.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return onMenu?() ?? () }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(event.modifierFlags) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick?([]); return true }
    override func isAccessibilityElement() -> Bool { true }
}

/// The colour menu bar glyphs have on a screen. macOS 27 picks it from the
/// wallpaper behind the translucent bar, so do the same: sample the top of
/// the desktop picture (no Screen Recording needed). Pictures in protected
/// folders (Downloads, Desktop, Documents…) would trigger a privacy prompt,
/// so those fall back to white, which most wallpapers get.
@MainActor
enum MenuBarTint {
    private static var cache: [URL: Bool] = [:]

    static func glyphColor(on screen: NSScreen) -> NSColor {
        isDark(screen) ? .white : NSColor.black.withAlphaComponent(0.85)
    }

    private static func isDark(_ screen: NSScreen) -> Bool {
        let workspace = NSWorkspace.shared
        // A solid bar follows the system appearance.
        if workspace.accessibilityDisplayShouldReduceTransparency {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        guard let url = workspace.desktopImageURL(for: screen), isReadableWithoutPrompt(url) else { return true }
        if let cached = cache[url] { return cached }
        let dark = topLuminance(of: url).map { $0 < 0.6 } ?? true
        cache[url] = dark
        return dark
    }

    private static func isReadableWithoutPrompt(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let safe = ["/System/Library/", "/Library/", library + "/Application Support/com.apple.wallpaper/"]
        return safe.contains { path.hasPrefix($0) }
    }

    /// Mean luminance of the top 4% of the image, from a small thumbnail.
    private static func topLuminance(of url: URL) -> CGFloat? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
            ] as CFDictionary)
        else { return nil }
        let width = thumbnail.width
        let rows = max(1, thumbnail.height / 25)
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Draw so that the image's top rows land in the context.
        context.draw(thumbnail, in: CGRect(x: 0, y: rows - thumbnail.height, width: width, height: thumbnail.height))
        var total: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])
        }
        return total / CGFloat(width * rows) / 255
    }
}
