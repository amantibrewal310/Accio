import AppKit
import Combine

/// Every menu bar item Accio has seen, in menu bar order (left to right).
///
/// Hidden items aren't drawn, so they disappear from MenuBarAgent's tree
/// while hidden. The registry remembers them, with their place next to the
/// item they were last seen beside, and persists the list so it survives
/// relaunches and apps that aren't running.
@MainActor
final class ItemRegistry: ObservableObject {
    static let shared = ItemRegistry()

    @Published private(set) var items: [MenuBarItem]
    /// IDs of items drawn in the menu bar at the last refresh.
    @Published private(set) var visibleIDs: Set<String> = []
    /// Running apps with menu bar items (bundle ID → item count), hidden or not.
    @Published private(set) var runningApps: [String: Int] = [:]
    /// Apple items that weren't in the bar the last time everything was
    /// shown. macOS adds some only in some states (Focus, Sound), and hidden
    /// items aren't drawn, so that's the only time to tell.
    @Published private(set) var absentSystemIDs: Set<String> = []

    private static let key = "KnownItems"

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [[String: String]] ?? []
        items = stored.compactMap(Self.decode)
        if items.isEmpty { items = Self.migratePhase1() }
    }

    func item(withID id: String) -> MenuBarItem? {
        items.first { $0.id == id }
    }

    /// The item's name, with its title or number for apps with several
    /// items (see `MenuBarItem.label`), numbered left to right.
    func label(of item: MenuBarItem) -> String {
        guard let bundleID = item.bundleID else { return item.name }
        let siblings = items.filter { $0.bundleID == bundleID }
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == item.id }) else { return item.name }
        return item.label(number: index + 1)
    }

    /// Whether the item is in the menu bar now, drawn or hidden.
    func isPresent(_ item: MenuBarItem) -> Bool {
        item.bundleID == nil ? !absentSystemIDs.contains(item.id) : isRunning(item)
    }

    func isRunning(_ item: MenuBarItem) -> Bool {
        // Apple's items belong to the system, which is always running.
        guard let bundleID = item.bundleID else { return true }
        return visibleIDs.contains(item.id) || runningApps[bundleID] != nil
    }

    /// Record what's drawn now. Visible items take their on-screen order;
    /// every other known item keeps its place right after the item it
    /// followed before. `everythingShown` when nothing is being hidden.
    func update(visible: [VisibleItem], everythingShown: Bool = false) {
        let live = visible.map(\.item)
        visibleIDs = Set(live.map(\.id))
        if everythingShown {
            let absent = Set(items.filter { $0.bundleID == nil }.map(\.id)).subtracting(visibleIDs)
            if absent != absentSystemIDs { absentSystemIDs = absent }
        }
        // MenuBarAgent's tree doesn't have apps' titles for their items.
        let titles = Dictionary(items.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var merged = live.map { item in
            var item = item
            if item.title == nil { item.title = titles[item.id] ?? nil }
            return item
        }
        var lastPlaced = -1
        for item in items {
            if let index = merged.firstIndex(where: { $0.id == item.id }) {
                lastPlaced = index
            } else {
                merged.insert(item, at: lastPlaced + 1)
                lastPlaced += 1
            }
        }
        commit(merged)
    }

    /// Record which apps have items, including hidden ones that `update(visible:)`
    /// can't see. Apps seen for the first time while hidden go to the left end.
    func update(apps: [MenuBarApp]) {
        runningApps = Dictionary(apps.map { ($0.bundleID, $0.itemCount) }, uniquingKeysWith: max)
        var merged = items
        for app in apps {
            // Forget items the app no longer has.
            merged.removeAll { item in
                guard item.bundleID == app.bundleID else { return false }
                return item.appIndex >= app.itemCount && !visibleIDs.contains(item.id)
            }
            for i in merged.indices where merged[i].bundleID == app.bundleID {
                merged[i].name = app.name
                let index = merged[i].appIndex
                if index < app.itemCount { merged[i].title = app.itemTitles[index] }
            }
            let missing = (0..<app.itemCount)
                .filter { index in !merged.contains { $0.id == MenuBarItem.appItemID(app.bundleID, index: index) } }
            merged.insert(contentsOf: missing.map {
                MenuBarItem(
                    id: MenuBarItem.appItemID(app.bundleID, index: $0), owner: .app(bundleID: app.bundleID),
                    name: app.name, title: app.itemTitles[$0]
                )
            }, at: 0)
        }
        commit(merged)
    }

    private func commit(_ merged: [MenuBarItem]) {
        guard merged != items else { return }
        items = merged
        UserDefaults.standard.set(merged.map(Self.encode), forKey: Self.key)
    }

    // MARK: Storage

    private static func encode(_ item: MenuBarItem) -> [String: String] {
        var entry = ["id": item.id, "name": item.name]
        switch item.owner {
        case .app(let bundleID): entry["app"] = bundleID
        case .system(let identifier): entry["system"] = identifier
        }
        entry["title"] = item.title
        return entry
    }

    private static func decode(_ entry: [String: String]) -> MenuBarItem? {
        guard let id = entry["id"], let name = entry["name"] else { return nil }
        let owner: MenuBarItem.Owner
        if let bundleID = entry["app"] {
            owner = .app(bundleID: bundleID)
        } else if let identifier = entry["system"] {
            owner = .system(identifier: identifier)
        } else {
            return nil
        }
        return MenuBarItem(id: id, owner: owner, name: name, title: entry["title"])
    }

    /// Phase 1 only remembered names of apps it had seen.
    private static func migratePhase1() -> [MenuBarItem] {
        let defaults = UserDefaults.standard
        guard let names = defaults.dictionary(forKey: "KnownApps") as? [String: String] else { return [] }
        defaults.removeObject(forKey: "KnownApps")
        return names.keys.sorted().map {
            MenuBarItem(id: MenuBarItem.appItemID($0, index: 0), owner: .app(bundleID: $0), name: names[$0]!)
        }
    }
}
