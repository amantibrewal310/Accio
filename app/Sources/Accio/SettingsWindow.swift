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
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsView() }
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
                Picker("Show hidden items", selection: $preferences.revealMode) {
                    ForEach(RevealMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Show when the pointer rests on empty menu bar space", isOn: $preferences.revealsOnHover)
                Toggle("Swipe down on the menu bar to show, up to hide", isOn: $preferences.revealsOnScroll)
            } footer: {
                Text(preferences.revealMode == .menuBar
                    ? "If revealed items don't fit next to the notch, Accio lists them in a menu under its icon."
                    : "The menu bar stays as it is: Accio lists hidden items in a menu under its icon. Hold ⌥ in the menu for a secondary click.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Hide again after", selection: $preferences.rehideDelay) {
                    ForEach(Preferences.rehideDelays, id: \.self) { seconds in
                        Text(Self.delayTitle(seconds)).tag(seconds)
                    }
                }
                Toggle("Hide again when clicking outside the menu bar", isOn: $preferences.rehidesOnOutsideClick)
            } footer: {
                Text("Click the wand to show or hide Hidden items, ⌥-click it to show Always Hidden items too. Right-click it for the menu. Keyboard shortcuts are in the Shortcuts tab.")
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
