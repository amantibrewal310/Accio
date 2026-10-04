import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    /// Stands in for the status item when the build can't keep it visible.
    private var standIn: StandInIcon?
    private let controller = VisibilityController.shared
    private let preferences = Preferences.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        preferences.onChange = { [weak self] change in
            self?.controller.preferencesChanged(change)
            if change == .shortcut { self?.registerHotKey() }
        }
        controller.onRevealChange = { [weak self] _ in self?.updateIcon() }
        if !MenuBarHider.keepsOwnIconVisible {
            let standIn = StandInIcon()
            standIn.onClick = { [weak self] flags in self?.handleClick(flags, isRightClick: false) }
            standIn.onMenu = { [weak self] view in self?.showMenu(from: view) }
            self.standIn = standIn
            controller.onHidingChange = { [weak self] hiding in
                guard let self else { return }
                self.standIn?.setVisible(hiding, image: self.statusItem?.button?.image)
            }
        }
        controller.start()
        registerHotKey()

        if !MenuBarApps.isTrusted || !UserDefaults.standard.bool(forKey: "HasLaunched") {
            UserDefaults.standard.set(true, forKey: "HasLaunched")
            SettingsWindow.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Accio again from Finder or Spotlight shows Settings.
        SettingsWindow.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.showAllForQuit()
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Accio"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        let revealed = controller.isRevealed
        let image = NSImage(
            systemSymbolName: revealed ? "wand.and.sparkles.inverse" : "wand.and.sparkles",
            accessibilityDescription: revealed ? "Accio: hidden items shown" : "Accio"
        )
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Accessibility presses (VoiceOver, AXPress) arrive without an event.
        guard let event = NSApp.currentEvent else { return controller.toggle() }
        handleClick(event.modifierFlags, isRightClick: event.type == .rightMouseUp)
    }

    private func handleClick(_ flags: NSEvent.ModifierFlags, isRightClick: Bool) {
        if isRightClick || flags.contains(.control) {
            showMenu(from: nil)
        } else if flags.contains(.option) {
            SettingsWindow.shared.show()
        } else {
            controller.toggle()
        }
    }

    /// From the status item, or from `view` (the stand-in icon) when given.
    private func showMenu(from view: NSView?) {
        let menu = NSMenu()
        let toggle = ClosureMenuItem(controller.isRevealed ? "Hide Items" : "Show Hidden Items") { [controller] in
            controller.toggle()
        }
        if let shortcut = preferences.revealShortcut, let key = shortcut.menuKeyEquivalent {
            toggle.keyEquivalent = key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        toggle.isEnabled = controller.isAvailable
        menu.addItem(toggle)
        if !controller.isAvailable {
            let note = NSMenuItem(title: "Hiding isn't available on this version of macOS", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Accio", key: "q") { NSApp.terminate(nil) })

        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
            return
        }
        // Attach the menu for this click only, so left-click keeps toggling.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey?.unregister()
        hotKey = nil
        guard let shortcut = preferences.revealShortcut else { return }
        hotKey = HotKey(shortcut) { VisibilityController.shared.toggle() }
        if hotKey == nil { log("[HotKey] \(shortcut.displayString) is taken by another app") }
    }

    /// While the shortcut recorder listens, the old hotkey mustn't swallow keys.
    func suspendHotKey(_ suspended: Bool) {
        if suspended {
            hotKey?.unregister()
            hotKey = nil
        } else if hotKey == nil {
            registerHotKey()
        }
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
