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

    private static let key = "KnownItems"

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [[String: String]] ?? []
        items = stored.compactMap(Self.decode)
        if items.isEmpty { items = Self.migratePhase1() }
    }

    func item(withID id: String) -> MenuBarItem? {
        items.first { $0.id == id }
    }

    func isRunning(_ item: MenuBarItem) -> Bool {
        // Apple's items belong to the system, which is always running.
        guard let bundleID = item.bundleID else { return true }
        return visibleIDs.contains(item.id) || runningApps[bundleID] != nil
    }

    /// Record what's drawn now. Visible items take their on-screen order;
    /// every other known item keeps its place right after the item it
    /// followed before.
    func update(visible: [VisibleItem]) {
        let live = visible.map(\.item)
        visibleIDs = Set(live.map(\.id))
        var merged = live
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
                guard item.bundleID == app.bundleID, let index = Self.index(of: item) else { return false }
                return index >= app.itemCount && !visibleIDs.contains(item.id)
            }
            for i in merged.indices where merged[i].bundleID == app.bundleID {
                merged[i].name = app.name
            }
            let missing = (0..<app.itemCount)
                .map { MenuBarItem.appItemID(app.bundleID, index: $0) }
                .filter { id in !merged.contains { $0.id == id } }
            merged.insert(contentsOf: missing.map {
                MenuBarItem(id: $0, owner: .app(bundleID: app.bundleID), name: app.name)
            }, at: 0)
        }
        commit(merged)
    }

    private func commit(_ merged: [MenuBarItem]) {
        guard merged != items else { return }
        items = merged
        UserDefaults.standard.set(merged.map(Self.encode), forKey: Self.key)
    }

    private static func index(of item: MenuBarItem) -> Int? {
        item.id.split(separator: "#").last.flatMap { Int($0) }
    }

    // MARK: Storage

    private static func encode(_ item: MenuBarItem) -> [String: String] {
        switch item.owner {
        case .app(let bundleID): ["id": item.id, "app": bundleID, "name": item.name]
        case .system(let identifier): ["id": item.id, "system": identifier, "name": item.name]
        }
    }

    private static func decode(_ entry: [String: String]) -> MenuBarItem? {
        guard let id = entry["id"], let name = entry["name"] else { return nil }
        if let bundleID = entry["app"] { return MenuBarItem(id: id, owner: .app(bundleID: bundleID), name: name) }
        if let identifier = entry["system"] { return MenuBarItem(id: id, owner: .system(identifier: identifier), name: name) }
        return nil
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
