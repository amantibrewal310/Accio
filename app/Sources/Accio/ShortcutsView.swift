import AppKit
import Combine
import SwiftUI

/// Settings tab with Accio's own shortcuts and one for each menu bar item.
struct ShortcutsView: View {
    @ObservedObject private var registry = ItemRegistry.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var recorder = RecorderState.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Show hidden items") { ShortcutRecorder(action: .reveal) }
                LabeledContent("Search menu bar items") { ShortcutRecorder(action: .search) }
            } footer: {
                footer("In search, type part of an item's name, then press Return to open it or ⌥Return for a secondary click.")
            }
            Section {
                ForEach(items) { item in
                    LabeledContent {
                        ShortcutRecorder(action: .item(item.id))
                    } label: {
                        HStack(spacing: 8) {
                            ItemIcon(item: item, size: 20)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(registry.label(of: item))
                        }
                        .opacity(registry.isPresent(item) ? 1 : 0.5)
                    }
                }
            } header: {
                Text("Menu Bar Items")
            } footer: {
                footer("A shortcut opens the item's menu, whether it's shown, hidden or Always Hidden.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if let notice = recorder.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    /// Items in the menu bar now, and any others that have a shortcut.
    private var items: [MenuBarItem] {
        registry.items.filter { item in
            !item.isAccio && (registry.isPresent(item) || preferences.shortcut(for: .item(item.id)) != nil)
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// Click, then press the new shortcut. Esc cancels, ⌫ clears. A shortcut
/// already used for something else moves here.
struct ShortcutRecorder: View {
    let action: Preferences.ShortcutAction
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var state = RecorderState.shared
    @ObservedObject private var center = ShortcutCenter.shared

    private var shortcut: Shortcut? { preferences.shortcut(for: action) }
    private var isRecording: Bool { state.recording == action }

    var body: some View {
        HStack(spacing: 6) {
            if center.unavailable.contains(action), !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app is using this shortcut.")
                    .accessibilityLabel("Another app is using this shortcut")
            }
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : shortcut?.displayString ?? "Record Shortcut")
                    .frame(minWidth: 110)
            }
            .accessibilityValue(shortcut?.displayString ?? "None")
            Button {
                preferences.setShortcut(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear shortcut")
            .accessibilityLabel("Clear shortcut")
            // Keep the column of recorders aligned.
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .disabled(shortcut == nil || isRecording)
        }
        .onDisappear { if isRecording { state.stop() } }
    }

    private func toggleRecording() {
        isRecording ? state.stop() : state.start(for: action)
    }
}

/// Which recorder is listening, held outside the views: one at a time.
@MainActor
final class RecorderState: ObservableObject {
    static let shared = RecorderState()

    @Published private(set) var recording: Preferences.ShortcutAction?
    /// Says where a shortcut was taken from, after recording one in use.
    @Published private(set) var notice: String?

    private var monitor: Any?
    private var noticeTask: Task<Void, Never>?

    func start(for action: Preferences.ShortcutAction) {
        stop()
        recording = action
        ShortcutCenter.shared.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { RecorderState.shared.record(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        ShortcutCenter.shared.suspend(false)
    }

    private func record(_ event: NSEvent) {
        guard let action = recording else { return }
        let preferences = Preferences.shared
        switch Int(event.keyCode) {
        case 53: // Esc
            stop()
        case 51 where event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty: // ⌫
            preferences.setShortcut(nil, for: action)
            stop()
        default:
            guard let shortcut = Shortcut(event: event) else { return NSSound.beep() }
            if let previous = preferences.action(for: shortcut), previous != action {
                show("\(shortcut.displayString) no longer \(Self.describe(previous)).")
            }
            preferences.setShortcut(shortcut, for: action)
            stop()
        }
    }

    private func show(_ notice: String) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private static func describe(_ action: Preferences.ShortcutAction) -> String {
        switch action {
        case .reveal: return "shows hidden items"
        case .search: return "opens search"
        case .item(let id):
            let registry = ItemRegistry.shared
            return "opens \(registry.item(withID: id).map(registry.label(of:)) ?? "another item")"
        }
    }
}
