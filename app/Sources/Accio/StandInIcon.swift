import AppKit
import ImageIO

/// Accio's icon for builds whose own status item gets hidden too (no team
/// signature, docs/spikes.md §1d): a small window drawn in the menu bar,
/// just left of the items that are still visible. The assertion only hides
/// status items, so this stays put. Shown only while hiding.
@MainActor
final class StandInIcon {
    private let panel: NSPanel
    private let button: StandInButton
    private var refreshTimer: Timer?

    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onMenu: ((NSView) -> Void)?

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

    func setVisible(_ visible: Bool, image: NSImage?) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard visible else { return panel.orderOut(nil) }
        button.image = image
        reposition()
        panel.orderFrontRegardless()
        // Items fade out for about a second after hiding starts, then the bar
        // settles; widths change later too (the clock), so keep following it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.reposition()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.reposition() }
        }
        refreshTimer?.tolerance = 1
    }

    private func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        // Left of the leftmost visible item, but never behind the notch.
        // Without Accessibility, just right of the notch (or the middle):
        // shown items are right-aligned, so that spot is usually free.
        let notchRight = screen.auxiliaryTopRightArea.map { screen.frame.minX + $0.minX }
        var x = MenuBarState.leftmostVisibleItemX(on: screen).map { $0 - Self.width }
            ?? notchRight.map { $0 + 4 } ?? screen.frame.midX
        if let notchRight { x = max(x, notchRight) }
        let frame = NSRect(x: x, y: screen.frame.maxY - height, width: Self.width, height: height)
        button.tint = MenuBarTint.glyphColor(on: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
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
