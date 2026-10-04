import Combine
import Foundation

/// Everything the user chooses, persisted in UserDefaults. Changes apply
/// immediately (no Apply button).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    var onChange: (@MainActor (Change) -> Void)?

    enum Change { case visibility, shortcut, rehide }

    /// Bundle IDs of apps whose items are hidden. New apps are shown.
    @Published var hiddenApps: Set<String> {
        didSet { save(Array(hiddenApps), Key.hiddenApps); onChange?(.visibility) }
    }

    /// Apple items kept visible while hiding.
    @Published var shownSystemItems: Set<SystemItem> {
        didSet { save(shownSystemItems.map(\.rawValue), Key.shownSystemItems); onChange?(.visibility) }
    }

    /// Apps seen with menu bar items (bundle ID → name), so hidden apps stay
    /// in the list while they're not running.
    @Published var knownApps: [String: String] {
        didSet { save(knownApps, Key.knownApps) }
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

    static let rehideDelays = [5, 10, 15, 30, 60, 0]

    private enum Key {
        static let hiddenApps = "HiddenApps"
        static let shownSystemItems = "ShownSystemItems"
        static let knownApps = "KnownApps"
        static let revealShortcut = "RevealShortcut"
        static let rehideDelay = "RehideDelay"
        static let rehidesOnOutsideClick = "RehidesOnOutsideClick"
    }

    private init() {
        hiddenApps = Set(defaults.stringArray(forKey: Key.hiddenApps) ?? [])
        // Accept strings too, as written by `defaults write … -array 0 1`.
        shownSystemItems = defaults.array(forKey: Key.shownSystemItems)
            .map { Set($0.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }.compactMap(SystemItem.init(rawValue:))) }
            ?? SystemItem.defaultShown
        knownApps = defaults.dictionary(forKey: Key.knownApps) as? [String: String] ?? [:]
        // An empty string means the user cleared the shortcut.
        revealShortcut = defaults.string(forKey: Key.revealShortcut).map(Shortcut.init(rawValue:)) ?? .defaultReveal
        rehideDelay = defaults.object(forKey: Key.rehideDelay) as? Int ?? 10
        rehidesOnOutsideClick = defaults.object(forKey: Key.rehidesOnOutsideClick) as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
