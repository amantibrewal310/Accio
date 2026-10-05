import AppKit

/// A standard menu under Accio's icon listing items that aren't in the menu
/// bar: hidden ones, or revealed ones that don't fit next to the notch.
/// Choosing one opens it (`ItemOpener`).
///
/// macOS 27 doesn't draw hidden items, so their glyphs can't be captured;
/// a real menu with each app's icon and name looks at home where a strip
/// of colourful icons wouldn't.
@MainActor
final class HiddenItemsMenu: NSObject, NSMenuDelegate {
    static let shared = HiddenItemsMenu()

    enum Content: Equatable {
        /// Hidden items, and with `all` the Always Hidden ones too.
        case hidden(all: Bool)
        /// Revealed items that don't fit in the menu bar.
        case overflow([MenuBarItem])
    }

    private(set) var isOpen = false
    /// Called when the menu opens or closes.
    var onChange: (@MainActor (Bool) -> Void)?
    /// Pops a menu up from Accio's icon. Returns once the menu has closed.
    var present: (@MainActor (NSMenu) -> Void)?

    private let registry = ItemRegistry.shared
    private let preferences = Preferences.shared

    /// Open the menu, unless it's open already or there's nothing to show
    /// for `.overflow`.
    func show(_ content: Content) {
        guard !isOpen, let present else { return }
        let items = items(for: content)
        if case .overflow = content, items.isEmpty { return }
        let menu = makeMenu(content, items)
        menu.delegate = self
        // Not from inside the click or key event that asked for it.
        DispatchQueue.main.async { present(menu) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        onChange?(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        onChange?(false)
    }

    // MARK: Building the menu

    private func makeMenu(_ content: Content, _ items: [MenuBarItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch content {
        case .overflow:
            menu.addItem(.sectionHeader(title: "Not Enough Room in the Menu Bar"))
            add(items, to: menu)
        case .hidden(let all):
            let alwaysHidden = items.filter { preferences.section(of: $0.owner) == .alwaysHidden }
            let hidden = items.filter { preferences.section(of: $0.owner) != .alwaysHidden }
            if items.isEmpty {
                let empty = NSMenuItem(title: "Nothing Is Hidden", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            add(hidden, to: menu)
            if all, !alwaysHidden.isEmpty {
                if !hidden.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: "Always Hidden"))
                add(alwaysHidden, to: menu)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Edit Layout…") { SettingsWindow.shared.show() })
        return menu
    }

    /// One entry per item; holding ⌥ turns each into a secondary click.
    private func add(_ items: [MenuBarItem], to menu: NSMenu) {
        let perApp = Dictionary(grouping: items.compactMap(\.bundleID), by: { $0 }).mapValues(\.count)
        var seen: [String: Int] = [:]
        for item in items {
            var number: Int?
            if let bundleID = item.bundleID, perApp[bundleID, default: 0] > 1 {
                // Apps with several items: their titles, or numbers left to right.
                seen[bundleID, default: 0] += 1
                number = seen[bundleID]
            }
            let title = item.label(number: number)
            let image = Self.icon(for: item)
            let open = ClosureMenuItem(title) { ItemOpener.shared.open(item) }
            open.image = image
            open.toolTip = item.title.map { "\(item.name): \($0)" } ?? item.name
            menu.addItem(open)
            let secondary = ClosureMenuItem("\(title) (Secondary Click)") { ItemOpener.shared.open(item, button: .right) }
            secondary.image = image
            secondary.isAlternate = true
            secondary.keyEquivalentModifierMask = .option
            menu.addItem(secondary)
        }
    }

    private static func icon(for item: MenuBarItem) -> NSImage? {
        if let symbol = item.symbolName {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            return image
        }
        guard let icon = AppIcons.icon(for: item.bundleID ?? "").copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    // MARK: Contents

    private func items(for content: Content) -> [MenuBarItem] {
        switch content {
        case .overflow(let items): return items
        case .hidden(let all):
            // Plus shown items that don't fit in the menu bar right now,
            // on the display the user is working in.
            let screen = Displays.active
            let visible = MenuBarItems.visible(on: Displays.activeID)
            let undrawn = MenuBarItems.undrawnIDs(in: visible, on: screen)
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
