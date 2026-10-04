import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Accio Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        VisibilityController.shared.rescan()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Menu Bar Items", systemImage: "menubar.rectangle") { ItemsView() }
            Tab("General", systemImage: "gearshape") { GeneralView() }
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: Items

private struct ItemsView: View {
    @ObservedObject private var controller = VisibilityController.shared
    @ObservedObject private var preferences = Preferences.shared
    private let trustPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !controller.isAvailable {
                Section {
                    Label("This version of macOS doesn't let Accio hide menu bar items.", systemImage: "exclamationmark.triangle")
                }
            }
            if controller.isAvailable, !MenuBarHider.keepsOwnIconVisible {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("This build of Accio isn't signed, so its own icon hides along with the rest.", systemImage: "eye.slash")
                        Text(revealHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !controller.isTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accio needs Accessibility access to see which apps have menu bar items.", systemImage: "lock")
                        Text("Hiding works without it, but the list below stays empty until access is granted.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Grant Access…") { MenuBarApps.requestAccess() }
                    }
                }
            }
            Section {
                if rows.isEmpty {
                    Text(controller.isTrusted ? "Looking for menu bar apps…" : "No apps yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    AppRow(row: row, isHidden: hiddenBinding(row.bundleID))
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Hiding works per app: an app with several icons shows or hides all of them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(SystemItem.allCases) { item in
                    VisibilityPicker(isHidden: systemBinding(item)) {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            } header: {
                Text("Apple")
            } footer: {
                Text("Focus and other Apple items not listed here are hidden whenever Accio is hiding something.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(trustPoll) { _ in
            if controller.isAvailable, !MenuBarHider.keepsOwnIconVisible {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("This build of Accio isn't signed, so its own icon hides along with the rest.", systemImage: "eye.slash")
                        Text(revealHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !controller.isTrusted { controller.refreshTrust() }
        }
    }

    private var revealHint: String {
        guard let shortcut = preferences.revealShortcut else {
            return "Set a shortcut in General to show hidden items, or open Accio again to get back here."
        }
        return "Press \(shortcut.displayString) to show hidden items, or open Accio again to get back here."
    }

    /// Running menu bar apps, plus hidden apps that aren't running right now.
    private var rows: [AppRowModel] {
        var rows = controller.menuBarApps.map {
            AppRowModel(bundleID: $0.bundleID, name: $0.name, itemCount: $0.itemCount, isRunning: true)
        }
        let running = Set(rows.map(\.bundleID))
        for bundleID in preferences.hiddenApps where !running.contains(bundleID) {
            rows.append(AppRowModel(
                bundleID: bundleID, name: preferences.knownApps[bundleID] ?? bundleID, itemCount: 0, isRunning: false
            ))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func hiddenBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { preferences.hiddenApps.contains(bundleID) },
            set: { hidden in
                if hidden { preferences.hiddenApps.insert(bundleID) } else { preferences.hiddenApps.remove(bundleID) }
            }
        )
    }

    private func systemBinding(_ item: SystemItem) -> Binding<Bool> {
        Binding(
            get: { !preferences.shownSystemItems.contains(item) },
            set: { hidden in
                if hidden { preferences.shownSystemItems.remove(item) } else { preferences.shownSystemItems.insert(item) }
            }
        )
    }
}

private struct AppRowModel: Identifiable {
    let bundleID: String
    let name: String
    let itemCount: Int
    let isRunning: Bool

    var id: String { bundleID }

    var subtitle: String? {
        if !isRunning { return "Not running" }
        return itemCount > 1 ? "\(itemCount) items" : nil
    }
}

private struct AppRow: View {
    let row: AppRowModel
    @Binding var isHidden: Bool

    var body: some View {
        VisibilityPicker(isHidden: $isHidden) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: row.bundleID))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(row.isRunning ? 1 : 0.6)
        }
    }
}

private struct VisibilityPicker<Label: View>: View {
    @Binding var isHidden: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        Picker(selection: $isHidden, content: {
            Text("Shown").tag(false)
            Text("Hidden").tag(true)
        }, label: label)
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

@MainActor
private enum AppIcons {
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

// MARK: General

private struct GeneralView: View {
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var loginItem = LoginItem.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Show hidden items") {
                    ShortcutRecorder(shortcut: $preferences.revealShortcut)
                }
                Picker("Hide again after", selection: $preferences.rehideDelay) {
                    ForEach(Preferences.rehideDelays, id: \.self) { seconds in
                        Text(Self.delayTitle(seconds)).tag(seconds)
                    }
                }
                Toggle("Hide again when clicking outside the menu bar", isOn: $preferences.rehidesOnOutsideClick)
            } footer: {
                Text("Click the wand to show or hide items. Right-click it for the menu, ⌥-click for Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $loginItem.isEnabled)
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
    }

    private static func delayTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Never"
        case 60: "1 minute"
        default: "\(seconds) seconds"
        }
    }
}

/// Accio's login item, via SMAppService.
@MainActor
private final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log("[Login] \(error)")
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, ⌫ clears.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @ObservedObject private var state = RecorderState.shared
    private var isRecording: Bool { state.monitor != nil }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : shortcut?.displayString ?? "Record Shortcut")
                    .frame(minWidth: 110)
            }
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        (NSApp.delegate as? AppDelegate)?.suspendHotKey(true)
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch Int(event.keyCode) {
                case 53: stopRecording() // Esc
                case 51 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: // ⌫
                    shortcut = nil
                    stopRecording()
                default:
                    guard let new = Shortcut(event: event) else { NSSound.beep(); return }
                    shortcut = new
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
        state.monitor = nil
        (NSApp.delegate as? AppDelegate)?.suspendHotKey(false)
    }
}

/// The recorder's key monitor, held outside the view (there is one recorder).
@MainActor
private final class RecorderState: ObservableObject {
    static let shared = RecorderState()
    @Published var monitor: Any?
}
