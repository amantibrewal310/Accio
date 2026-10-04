import AppKit
import Combine
import SwiftUI

/// Settings tab with every menu bar item in three rows (Shown, Hidden,
/// Always Hidden), in menu bar order. Dragging an item to another row
/// changes when it shows; dropping it onto another item also moves it next
/// to that item in the real menu bar.
struct LayoutView: View {
    @ObservedObject private var controller = VisibilityController.shared
    @ObservedObject private var registry = ItemRegistry.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var mover = ItemMover.shared
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banners
                Text("Drag items between rows to choose when they show. Drop an item onto another to put it next to that item in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ItemSection.allCases) { section in
                    Shelf(section: section, subtitle: subtitle(for: section), items: items(in: section))
                }
                status
                tidy
                Text("Hiding works per app: moving one of an app's items to another row moves all of them. Apple items with a lock, like Focus, can't stay visible while Accio hides anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onReceive(poll) { _ in
            controller.refreshTrust()
            if mover.movingID == nil { controller.rescan() }
        }
    }

    @ViewBuilder private var banners: some View {
        if !controller.isAvailable {
            Banner(systemImage: "exclamationmark.triangle", text: "This version of macOS doesn't let Accio hide menu bar items.")
        }
        if !controller.isTrusted {
            Banner(systemImage: "lock", text: "Accio needs Accessibility access to see your menu bar items and move them.") {
                Button("Grant Access…") { MenuBarItems.requestAccess() }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let id = mover.movingID {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(mover.isTidying
                    ? "Tidying up: moving \(registry.item(withID: id)?.name ?? "an item")…"
                    : "Moving \(registry.item(withID: id)?.name ?? "item")…")
            }
            .font(.callout)
        } else if let failure = mover.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    /// Hidden items left of Accio and shown ones right of it keep Accio's
    /// icon in one place when they show and hide.
    private var tidy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isTidy ? "checkmark.circle" : "arrow.left.arrow.right.circle")
                .foregroundStyle(isTidy ? Color.secondary : Color.orange)
            Text(isTidy
                ? "Hidden items are left of Accio and shown items right of it, so the wand stays put when they show and hide."
                : "Some items are on the wrong side of Accio, so the wand moves when hidden items show and hide. Tidy Up puts hidden items to its left and shown items to its right.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Tidy Up") { Task { await mover.tidy() } }
                .disabled(mover.movingID != nil || !controller.isTrusted)
        }
    }

    /// Whether every running item is on its section's side of Accio, going
    /// by where items were last drawn.
    private var isTidy: Bool {
        let relevant = registry.items.filter { item in
            item.isAccio || registry.visibleIDs.contains(item.id) || (item.bundleID != nil && registry.isRunning(item))
        }
        guard let accio = relevant.firstIndex(where: \.isAccio) else { return true }
        return relevant.indices.allSatisfy { index in
            index == accio || (preferences.section(of: relevant[index].owner) == .shown) == (index > accio)
        }
    }

    private func subtitle(for section: ItemSection) -> String {
        switch section {
        case .shown: return "Always in the menu bar"
        case .hidden:
            let shortcut = preferences.revealShortcut.map { " or press \($0.displayString)" } ?? ""
            return "Shown when you click Accio\(shortcut)"
        case .alwaysHidden: return "Shown when you ⌥-click Accio"
        }
    }

    /// Items in `section`, in menu bar order. Shown items that aren't in the
    /// bar any more are left out; hidden ones stay, so they can be shown again.
    private func items(in section: ItemSection) -> [MenuBarItem] {
        registry.items.filter { item in
            !item.isAccio && preferences.section(of: item.owner) == section && (section != .shown || registry.isRunning(item))
        }
    }
}

private struct Banner<Accessory: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }
}

extension Banner where Accessory == EmptyView {
    init(systemImage: String, text: String) {
        self.init(systemImage: systemImage, text: text) { EmptyView() }
    }
}

/// One row of the layout editor.
private struct Shelf: View {
    let section: ItemSection
    let subtitle: String
    let items: [MenuBarItem]
    @ObservedObject private var drop = LayoutDrop.shared

    private var isTargeted: Bool { drop.target == .section(section) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    Tile(item: item, section: section)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .overlay {
                if items.isEmpty {
                    Text("Drag items here").foregroundStyle(.tertiary)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .dropDestination(for: String.self) { ids, _ in
                drop.drop(ids.first, into: section, beside: nil)
            } isTargeted: { targeted in
                drop.setTarget(.section(section), targeted)
            }
        }
    }
}

/// An item: its app's icon (or an SF Symbol for Apple items) and name.
private struct Tile: View {
    let item: MenuBarItem
    let section: ItemSection
    @ObservedObject private var drop = LayoutDrop.shared
    @ObservedObject private var mover = ItemMover.shared
    @ObservedObject private var registry = ItemRegistry.shared
    private let preferences = Preferences.shared

    private static let size = CGSize(width: 76, height: 66)

    private var isTargeted: Bool { drop.target == .item(item.id) }
    private var isLocked: Bool { !preferences.canPlace(item.owner, in: .shown) }
    private var isRunning: Bool { registry.isRunning(item) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ItemIcon(item: item)
                if mover.movingID == item.id {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.gray))
                        .offset(x: 4, y: 4)
                }
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 4)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .opacity(isRunning ? 1 : 0.5)
        .contentShape(Rectangle())
        .draggable(item.id) {
            ItemIcon(item: item).frame(width: 32, height: 32)
        }
        .dropDestination(for: String.self) { ids, location in
            drop.drop(ids.first, into: section, beside: (item, location.x < Self.size.width / 2 ? .left : .right))
        } isTargeted: { targeted in
            drop.setTarget(.item(item.id), targeted)
        }
        .contextMenu {
            ForEach(ItemSection.allCases) { target in
                Button("Move to \(target.title)") {
                    _ = drop.drop(item.id, into: target, beside: nil)
                }
                .disabled(target == section || !preferences.canPlace(item.owner, in: target))
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(section.title)")
        .accessibilityHint("Use the context menu to move it to another row.")
    }

    private var help: String {
        if isLocked { return "\(item.name) is hidden whenever Accio hides anything; macOS doesn't let it stay visible." }
        if !isRunning { return "\(item.name) isn't running." }
        return item.name
    }
}

private struct ItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        switch item.owner {
        case .app(let bundleID):
            Image(nsImage: AppIcons.icon(for: bundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .system:
            Image(systemName: item.symbolName ?? "menubar.rectangle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
        }
    }
}

/// Drop targeting and handling for the layout editor.
@MainActor
private final class LayoutDrop: ObservableObject {
    static let shared = LayoutDrop()

    enum Target: Equatable {
        case section(ItemSection)
        case item(String)
    }

    @Published private(set) var target: Target?

    func setTarget(_ target: Target, _ isTargeted: Bool) {
        if isTargeted {
            self.target = target
        } else if self.target == target {
            self.target = nil
        }
    }

    /// Put the item with `id` in `section`, and next to `beside` in the menu bar when given.
    func drop(_ id: String?, into section: ItemSection, beside: (item: MenuBarItem, side: ItemMover.Side)?) -> Bool {
        target = nil
        let registry = ItemRegistry.shared
        let preferences = Preferences.shared
        guard let id, let item = registry.item(withID: id), preferences.canPlace(item.owner, in: section) else { return false }
        let wasShown = preferences.section(of: item.owner) == .shown
        preferences.setSection(section, for: item.owner)
        if let beside, beside.item.id != item.id, registry.isRunning(item), registry.isRunning(beside.item) {
            Task { await ItemMover.shared.move(item, to: beside.side, of: beside.item) }
        } else if wasShown != (section == .shown), registry.isRunning(item) {
            // Across Accio, so its icon stays put when the item shows and hides.
            Task { await ItemMover.shared.tidy(only: item) }
        }
        return true
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let icon = cache[bundleID] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        cache[bundleID] = icon
        return icon
    }
}
