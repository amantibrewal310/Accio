import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// Stand-ins for the status item when the build can't keep it visible.
    private var standIn: StandInIcons?
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
            if change == .shortcut { ShortcutCenter.shared.register() }
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
            let presence = MenuBarPresence.shared
            presence.onChange = { [weak self] display, shown in self?.standIn?.setMenuBarShown(shown, on: display) }
            presence.start()
            let standIn = StandInIcons()
            standIn.onClick = { [weak self] flags in self?.handleClick(flags, isRightClick: false) }
            standIn.onMenu = { [weak self] in self?.showMenu() }
            standIn.staysVisible = { [controller] item in controller.staysVisible(item) }
            ItemOpener.shared.onClickSlot = { [weak standIn] slot in standIn?.makeRoom(for: slot) }
            self.standIn = standIn
            controller.onHidingChange = { [weak self] hiding in
                guard let self else { return }
                self.standIn?.setVisible(hiding, image: self.statusItem?.button?.image)
            }
        }
        controller.start()
        ShortcutCenter.shared.perform = { [weak self] action in self?.perform(action) }
        ShortcutCenter.shared.register()
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
        case .menuBar where isMenuBarAway && !controller.isRevealed:
            // Items revealed in a menu bar that has slid away can't be seen.
            itemsMenu.show(.hidden(all: all))
        case .menuBar:
            if !all { return controller.toggle() }
            controller.revealLevel == .all ? controller.hide() : controller.reveal(all: true)
        }
    }

    /// Whether the menu bar of the display the user is in has slid away
    /// (full screen, or set to hide) and the pointer isn't bringing it back.
    private var isMenuBarAway: Bool {
        guard let screen = Displays.active else { return false }
        return MenuBarPresence.autoHides(screen) && !MenuBarState.isMouseInMenuBar
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
        let search = ClosureMenuItem("Search Menu Bar…") { SearchPanel.shared.show() }
        if let shortcut = preferences.searchShortcut, let key = shortcut.menuKeyEquivalent {
            search.keyEquivalent = key
            search.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(search)
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
        if let standIn, standIn.popUp(menu) { return }
        // Attach the menu for this click only, so left-click keeps toggling.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: Shortcuts

    private func perform(_ action: Preferences.ShortcutAction) {
        switch action {
        case .reveal:
            toggleItems(all: false)
        case .search:
            SearchPanel.shared.toggle()
        case .item(let id):
            let registry = ItemRegistry.shared
            guard let item = registry.item(withID: id), registry.isPresent(item) else { return NSSound.beep() }
            ItemOpener.shared.open(item)
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
