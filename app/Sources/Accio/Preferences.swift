import Combine
import Foundation

/// Where an item goes when Accio hides things.
enum ItemSection: String, CaseIterable, Identifiable, Sendable {
    /// Always in the menu bar.
    case shown
    /// Shown when the user reveals hidden items.
    case hidden
    /// Shown only when the user reveals everything (⌥-click).
    case alwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

/// Where hidden items appear when the user asks for them.
enum RevealMode: String, CaseIterable, Identifiable, Sendable {
    /// In the menu bar itself; items that don't fit are offered in a menu.
    case menuBar
    /// In a menu under Accio's icon; the menu bar stays as it is.
    case bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBar: "In the menu bar"
        case .bar: "In a menu"
        }
    }
}

/// Everything the user chooses, persisted in UserDefaults. Changes apply
/// immediately (no Apply button).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    var onChange: (@MainActor (Change) -> Void)?

    enum Change { case visibility, shortcut, rehide, reveal }

    /// Bundle IDs of apps in the Hidden section. New apps are shown.
    @Published private(set) var hiddenApps: Set<String> {
        didSet { save(Array(hiddenApps), Key.hiddenApps); onChange?(.visibility) }
    }

    /// Bundle IDs of apps in the Always Hidden section.
    @Published private(set) var alwaysHiddenApps: Set<String> {
        didSet { save(Array(alwaysHiddenApps), Key.alwaysHiddenApps); onChange?(.visibility) }
    }

    /// Apple items kept visible while hiding.
    @Published private(set) var shownSystemItems: Set<SystemItem> {
        didSet { save(shownSystemItems.map(\.rawValue), Key.shownSystemItems); onChange?(.visibility) }
    }

    /// Apple items in the Always Hidden section.
    @Published private(set) var alwaysHiddenSystemItems: Set<SystemItem> {
        didSet { save(alwaysHiddenSystemItems.map(\.rawValue), Key.alwaysHiddenSystemItems); onChange?(.visibility) }
    }

    @Published var revealShortcut: Shortcut? {
        didSet { save(revealShortcut?.rawValue ?? "", Key.revealShortcut); onChange?(.shortcut) }
    }

    /// Seconds before revealed items hide again; 0 means never.
    @Published var rehideDelay: Int {
        didSet { save(rehideDelay, Key.rehideDelay); onChange?(.rehide) }
    }

    @Published var rehidesOnOutsideClick: Bool {
        didSet { save(rehidesOnOutsideClick, Key.rehidesOnOutsideClick); onChange?(.rehide) }
    }

    @Published var revealMode: RevealMode {
        didSet { save(revealMode.rawValue, Key.revealMode); onChange?(.reveal) }
    }

    /// Show hidden items when the pointer rests on empty menu bar space.
    @Published var revealsOnHover: Bool {
        didSet { save(revealsOnHover, Key.revealsOnHover); onChange?(.reveal) }
    }

    /// Swipe or scroll down on the menu bar to show hidden items, up to hide them.
    @Published var revealsOnScroll: Bool {
        didSet { save(revealsOnScroll, Key.revealsOnScroll); onChange?(.reveal) }
    }

    static let rehideDelays = [5, 10, 15, 30, 60, 0]

    private enum Key {
        static let hiddenApps = "HiddenApps"
        static let alwaysHiddenApps = "AlwaysHiddenApps"
        static let shownSystemItems = "ShownSystemItems"
        static let alwaysHiddenSystemItems = "AlwaysHiddenSystemItems"
        static let revealShortcut = "RevealShortcut"
        static let rehideDelay = "RehideDelay"
        static let rehidesOnOutsideClick = "RehidesOnOutsideClick"
        static let revealMode = "RevealMode"
        static let revealsOnHover = "RevealsOnHover"
        static let revealsOnScroll = "RevealsOnScroll"
    }

    private init() {
        hiddenApps = Set(defaults.stringArray(forKey: Key.hiddenApps) ?? [])
        alwaysHiddenApps = Set(defaults.stringArray(forKey: Key.alwaysHiddenApps) ?? [])
        shownSystemItems = Self.systemItems(defaults.array(forKey: Key.shownSystemItems)) ?? SystemItem.defaultShown
        alwaysHiddenSystemItems = Self.systemItems(defaults.array(forKey: Key.alwaysHiddenSystemItems)) ?? []
        // An empty string means the user cleared the shortcut.
        revealShortcut = defaults.string(forKey: Key.revealShortcut).map(Shortcut.init(rawValue:)) ?? .defaultReveal
        rehideDelay = defaults.object(forKey: Key.rehideDelay) as? Int ?? 10
        rehidesOnOutsideClick = defaults.object(forKey: Key.rehidesOnOutsideClick) as? Bool ?? true
        revealMode = defaults.string(forKey: Key.revealMode).flatMap(RevealMode.init(rawValue:)) ?? .menuBar
        revealsOnHover = defaults.bool(forKey: Key.revealsOnHover)
        revealsOnScroll = defaults.bool(forKey: Key.revealsOnScroll)
    }

    /// Accepts strings too, as written by `defaults write … -array 0 1`.
    private static func systemItems(_ array: [Any]?) -> Set<SystemItem>? {
        array.map { Set($0.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }.compactMap(SystemItem.init(rawValue:))) }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Sections

    func section(of owner: MenuBarItem.Owner) -> ItemSection {
        switch owner {
        case .app(let bundleID):
            if alwaysHiddenApps.contains(bundleID) { return .alwaysHidden }
            return hiddenApps.contains(bundleID) ? .hidden : .shown
        case .system(let identifier):
            // Apple items the API can't name are hidden whenever Accio hides anything.
            guard let item = SystemItem(menuExtraIdentifier: identifier) else { return .hidden }
            if alwaysHiddenSystemItems.contains(item) { return .alwaysHidden }
            return shownSystemItems.contains(item) ? .shown : .hidden
        }
    }

    /// Whether `owner` can be put in `section`. Apple items outside
    /// `SystemItem` (Focus…) can only be Hidden.
    func canPlace(_ owner: MenuBarItem.Owner, in section: ItemSection) -> Bool {
        if case .system(let identifier) = owner, SystemItem(menuExtraIdentifier: identifier) == nil {
            return section == .hidden
        }
        return true
    }

    /// Moves every item of `owner`'s app (or the Apple item) to `section`.
    func setSection(_ section: ItemSection, for owner: MenuBarItem.Owner) {
        guard canPlace(owner, in: section), self.section(of: owner) != section else { return }
        switch owner {
        case .app(let bundleID):
            if section == .hidden { hiddenApps.insert(bundleID) } else { hiddenApps.remove(bundleID) }
            if section == .alwaysHidden { alwaysHiddenApps.insert(bundleID) } else { alwaysHiddenApps.remove(bundleID) }
        case .system(let identifier):
            guard let item = SystemItem(menuExtraIdentifier: identifier) else { return }
            if section == .shown { shownSystemItems.insert(item) } else { shownSystemItems.remove(item) }
            if section == .alwaysHidden { alwaysHiddenSystemItems.insert(item) } else { alwaysHiddenSystemItems.remove(item) }
        }
    }
}
