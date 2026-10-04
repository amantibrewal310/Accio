import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    /// Stands in for the status item when the build can't keep it visible.
    private var standIn: StandInIcon?
    private let controller = VisibilityController.shared
    private let preferences = Preferences.shared
    private let itemsMenu = HiddenItemsMenu.shared
    /// When the user last asked to see hidden items (click, hotkey or menu),
    /// so items that don't fit only pop up in a menu right after they asked.
    private var lastRevealRequest = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        preferences.onChange = { [weak self] change in
            self?.controller.preferencesChanged(change)
            if change == .shortcut { self?.registerHotKey() }
            if change == .reveal { self?.revealSettingsChanged() }
        }
        controller.onRevealChange = { [weak self] _ in self?.updateIcon() }
        controller.onOverflow = { [weak self] items in
            // Items that don't fit next to the notch: offer them in a menu,
            // if the user just asked for them and isn't in another menu.
            guard let self, self.preferences.revealMode == .menuBar, !items.isEmpty,
                  Date().timeIntervalSince(self.lastRevealRequest) < 3, !MenuBarState.isMenuOpen
            else { return }
            self.itemsMenu.show(.overflow(items))
        }
        itemsMenu.onChange = { [weak self] _ in self?.updateIcon() }
        itemsMenu.present = { [weak self] menu in self?.popUp(menu) }
        let triggers = MenuBarTriggers.shared
        triggers.onHover = { [weak self] in self?.showItems() }
        triggers.onScroll = { [weak self] down in down ? self?.showItems() : self?.hideItems() }
        if !MenuBarHider.keepsOwnIconVisible {
            let standIn = StandInIcon()
            standIn.onClick = { [weak self] flags in self?.handleClick(flags, isRightClick: false) }
            standIn.onMenu = { [weak self] _ in self?.showMenu() }
            standIn.staysVisible = { [controller] item in controller.staysVisible(item) }
            self.standIn = standIn
            let presence = MenuBarPresence.shared
            presence.onChange = { [weak self] shown in self?.standIn?.isMenuBarShown = shown }
            presence.start()
            standIn.isMenuBarShown = presence.isShown
            controller.onHidingChange = { [weak self] hiding in
                guard let self else { return }
                self.standIn?.setVisible(hiding, image: self.statusItem?.button?.image)
            }
        }
        controller.start()
        registerHotKey()
        revealSettingsChanged()

        if !MenuBarItems.isTrusted || !UserDefaults.standard.bool(forKey: "HasLaunched") {
            UserDefaults.standard.set(true, forKey: "HasLaunched")
            OnboardingWindow.shared.show()
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
        let revealed = controller.isRevealed || itemsMenu.isOpen
        let image = NSImage(
            systemSymbolName: revealed ? "wand.and.sparkles.inverse" : "wand.and.sparkles",
            accessibilityDescription: revealed ? "Accio: hidden items shown" : "Accio"
        )
        image?.isTemplate = true
        statusItem?.button?.image = image
        standIn?.image = image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Accessibility presses (VoiceOver, AXPress) arrive without an event.
        guard let event = NSApp.currentEvent else { return toggleItems(all: false) }
        handleClick(event.modifierFlags, isRightClick: event.type == .rightMouseUp)
    }

    private func handleClick(_ flags: NSEvent.ModifierFlags, isRightClick: Bool) {
        if isRightClick || flags.contains(.control) {
            showMenu()
        } else {
            // ⌥: Always Hidden items too; a second ⌥-click hides again.
            toggleItems(all: flags.contains(.option))
        }
    }

    // MARK: Showing items

    /// Show or hide hidden items, in the menu bar or a menu as the user chose.
    private func toggleItems(all: Bool) {
        lastRevealRequest = Date()
        switch preferences.revealMode {
        case .bar:
            // An open menu closes by itself on the next click or key.
            itemsMenu.show(.hidden(all: all))
        case .menuBar:
            if !all { return controller.toggle() }
            controller.revealLevel == .all ? controller.hide() : controller.reveal(all: true)
        }
    }

    private func showItems() {
        switch preferences.revealMode {
        case .bar: itemsMenu.show(.hidden(all: false))
        case .menuBar: controller.reveal()
        }
    }

    private func hideItems() {
        if preferences.revealMode == .menuBar { controller.hide() }
    }

    private func revealSettingsChanged() {
        // Don't leave items out in the menu bar after switching to the menu.
        if preferences.revealMode == .bar { controller.hide() }
        MenuBarTriggers.shared.update(hover: preferences.revealsOnHover, scroll: preferences.revealsOnScroll)
    }

    /// Accio's own menu (right-click).
    private func showMenu() {
        let menu = NSMenu()
        let showsMenu = preferences.revealMode == .bar
        let toggle = ClosureMenuItem(!showsMenu && controller.isRevealed ? "Hide Items" : "Show Hidden Items") { [weak self] in
            self?.toggleItems(all: false)
        }
        if let shortcut = preferences.revealShortcut, let key = shortcut.menuKeyEquivalent {
            toggle.keyEquivalent = key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        toggle.isEnabled = controller.isAvailable
        menu.addItem(toggle)
        if showsMenu || controller.revealLevel != .all {
            let all = ClosureMenuItem("Show All Items") { [weak self] in self?.toggleItems(all: true) }
            all.isEnabled = controller.isAvailable
            menu.addItem(all)
        }
        if !controller.isAvailable {
            let note = NSMenuItem(title: "Hiding isn't available on this version of macOS", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Accio", key: "q") { NSApp.terminate(nil) })
        popUp(menu)
    }

    /// Pop `menu` up from Accio's icon: the stand-in while it's shown, else
    /// the status item. Returns once the menu has closed.
    private func popUp(_ menu: NSMenu) {
        if let standIn, let view = standIn.anchorView {
            standIn.isHighlighted = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
            standIn.isHighlighted = false
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
        hotKey = HotKey(shortcut) { [weak self] in self?.toggleItems(all: false) }
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
