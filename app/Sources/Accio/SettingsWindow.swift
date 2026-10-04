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
            Tab("Layout", systemImage: "menubar.rectangle") { LayoutView() }
            Tab("General", systemImage: "gearshape") { GeneralView() }
        }
        .frame(width: 560, height: 620)
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
                Text("Click the wand to show or hide Hidden items, ⌥-click it to show Always Hidden items too. Right-click it for the menu.")
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
