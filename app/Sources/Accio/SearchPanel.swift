import AppKit
import Combine
import SwiftUI

/// Spotlight-style search for menu bar items: type part of an app's or an
/// item's name, pick it with ↑↓ and Return, and its menu opens, shown or
/// hidden (`ItemOpener`). ⌥Return makes it a secondary click.
///
/// A non-activating panel: the app the user is in stays active, so its
/// menus, and the room they leave for items next to the notch, don't change.
@MainActor
final class SearchPanel: NSObject, NSWindowDelegate {
    static let shared = SearchPanel()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let model = SearchModel()
    /// Where the panel's top edge goes, as it grows and shrinks with the results.
    private var top: CGFloat = 0

    static let width: CGFloat = 600

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        isOpen ? close() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.reset()
        // Pick up items that came or went since the last scan.
        VisibilityController.shared.rescan { [model] in model.refresh() }
        if let screen = Displays.active {
            // A little above the middle, like Spotlight.
            let frame = screen.frame
            top = frame.maxY - (frame.height * 0.22).rounded()
            panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.width / 2).rounded(), y: top - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        startMonitoringKeys()
    }

    func close() {
        stopMonitoringKeys()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = SearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("Search menu bar items")
        let view = SearchView(
            model: model,
            onHeight: { [weak self] height in self?.resize(to: height) },
            onOpen: { [weak self] item, button in self?.open(item, button: button) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    /// Grow or shrink with the results, keeping the top edge in place.
    private func resize(to height: CGFloat) {
        guard let panel, height > 0, panel.frame.height != height else { return }
        let origin = panel.isVisible ? NSPoint(x: panel.frame.minX, y: top - height) : panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        panel.invalidateShadow()
    }

    private func open(_ item: MenuBarItem, button: ItemOpener.Button) {
        close()
        SearchHistory.record(item)
        // Once the panel is gone and the user's app has the keyboard back.
        DispatchQueue.main.async { ItemOpener.shared.open(item, button: button) }
    }

    // MARK: Keys

    /// ↑↓ (and ⌃P ⌃N) move, Return opens, Esc clears the field, then closes.
    /// Taken before the text field sees them.
    private func startMonitoringKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { SearchPanel.shared.handle(event) } ? nil : event
        }
    }

    private func stopMonitoringKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Whether the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch (Int(event.keyCode), modifiers) {
        case (125, []), (45, .control): // ↓, ⌃N
            model.move(by: 1)
        case (126, []), (35, .control): // ↑, ⌃P
            model.move(by: -1)
        case (36, []), (76, []): // Return, Enter
            openSelection(.left)
        case (36, .option), (76, .option):
            openSelection(.right)
        case (53, []): // Esc
            if model.query.isEmpty { close() } else { model.query = "" }
        case (13, .command): // ⌘W
            close()
        default:
            return false
        }
        return true
    }

    private func openSelection(_ button: ItemOpener.Button) {
        guard let item = model.selectedItem else { return NSSound.beep() }
        open(item, button: button)
    }
}

/// Borderless panels don't take the keyboard unless they say they can.
private final class SearchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: Results

@MainActor
private final class SearchModel: ObservableObject {
    struct Result: Identifiable, Equatable {
        let item: MenuBarItem
        let label: String
        let section: ItemSection
        let shortcut: Shortcut?

        var id: String { item.id }

        var accessibilityLabel: String {
            let shortcut = shortcut.map { ", \($0.displayString)" } ?? ""
            return "\(label), \(section.title)\(shortcut)"
        }
    }

    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var results: [Result] = []
    @Published private(set) var selection = 0
    /// Bumped each time the panel opens, to put the cursor in the field.
    @Published private(set) var focusRequest = 0

    var selectedItem: MenuBarItem? {
        results.indices.contains(selection) ? results[selection].item : nil
    }

    func reset() {
        query = ""
        refresh()
        selection = 0
        focusRequest += 1
    }

    func move(by offset: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + offset + results.count) % results.count
        announceSelection()
    }

    /// Items in the menu bar now, best match first; with no query, the
    /// ones opened from here recently, then the rest in menu bar order.
    func refresh() {
        let registry = ItemRegistry.shared
        let preferences = Preferences.shared
        let selected = selectedItem?.id
        let candidates = registry.items.filter { !$0.isAccio && registry.isPresent($0) }
        let ranked: [MenuBarItem]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let recent = SearchHistory.recentIDs
            ranked = candidates.enumerated().sorted { a, b in
                let ra = recent.firstIndex(of: a.element.id) ?? .max
                let rb = recent.firstIndex(of: b.element.id) ?? .max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        } else {
            ranked = candidates.enumerated()
                .compactMap { index, item in score(item, label: registry.label(of: item)).map { (item, $0, index) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .map(\.0)
        }
        let results = ranked.map {
            Result(
                item: $0, label: registry.label(of: $0), section: preferences.section(of: $0.owner),
                shortcut: preferences.shortcut(for: .item($0.id))
            )
        }
        if results != self.results { self.results = results }
        selection = results.firstIndex { $0.id == selected } ?? 0
        if query.isEmpty { selection = 0 }
    }

    /// The best match among the item's names. Other words for Apple's items
    /// count only when they start with the query, and for less.
    private func score(_ item: MenuBarItem, label: String) -> Int? {
        let names = [label, item.name, item.title].compactMap { $0 }
        let best = names.compactMap { FuzzyMatch.score(query, in: $0) }.max()
        let keyword = (item.systemItem?.keywords ?? [])
            .compactMap { FuzzyMatch.score(query, in: $0) }
            .filter { $0 >= FuzzyMatch.prefixScore }
            .map { $0 - 300 }
            .max()
        return [best, keyword].compactMap { $0 }.max()
    }

    /// The selection moves while VoiceOver's focus stays in the text field.
    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, results.indices.contains(selection) else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: results[selection].accessibilityLabel, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

/// Items recently opened from search, most recent first, so an empty
/// search starts with them.
@MainActor
enum SearchHistory {
    private static let key = "RecentSearchItems"

    static var recentIDs: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ item: MenuBarItem) {
        let ids = [item.id] + recentIDs.filter { $0 != item.id }
        UserDefaults.standard.set(Array(ids.prefix(8)), forKey: key)
    }
}

// MARK: View

private struct SearchView: View {
    @ObservedObject var model: SearchModel
    let onHeight: (CGFloat) -> Void
    let onOpen: (MenuBarItem, ItemOpener.Button) -> Void
    @FocusState private var isFieldFocused: Bool

    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            field
            if !model.results.isEmpty {
                Divider()
                results
            } else if !model.query.isEmpty {
                Divider()
                Text("No menu bar items match “\(model.query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: SearchPanel.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .onAppear { isFieldFocused = true }
        .onChange(of: model.focusRequest) { isFieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Menu Bar", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($isFieldFocused)
                .accessibilityLabel("Search menu bar items")
                .accessibilityHint("Use the up and down arrow keys to choose an item, and Return to open it.")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        Row(result: result, isSelected: index == model.selection)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(result.item, NSEvent.modifierFlags.contains(.option) ? .right : .left) }
                            .id(result.id)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(height: CGFloat(min(model.results.count, Self.visibleRows)) * Self.rowHeight + 12)
            .onChange(of: model.selection) {
                guard model.results.indices.contains(model.selection) else { return }
                proxy.scrollTo(model.results[model.selection].id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }
}

private struct Row: View {
    let result: SearchModel.Result
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: result.item, size: 26)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.label)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(result.section.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            if let shortcut = result.shortcut {
                Text(shortcut.displayString)
                    .font(.callout)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
