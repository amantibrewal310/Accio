import AppKit
import Combine
import SwiftUI

/// Shown on first launch, and on launches without Accessibility access:
/// what Accio does, the one permission it needs, and how to use it.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView { [weak self] in
                self?.close()
            }))
            window.title = "Welcome to Accio"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        SettingsWindow.shared.show()
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @ObservedObject private var controller = VisibilityController.shared
    private let trustPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Welcome to Accio").font(.title.weight(.semibold))
                Text("Accio tidies your menu bar: it hides the items you don't need all the time, and brings them back when you ask.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Step(
                    systemImage: controller.isTrusted ? "checkmark.circle.fill" : "hand.raised.circle",
                    tint: controller.isTrusted ? .green : .accentColor,
                    title: "Allow Accessibility access",
                    detail: controller.isTrusted
                        ? "Done. Accio can see and arrange your menu bar items."
                        : "Accio uses it to see which items are in your menu bar and to move them. Nothing leaves your Mac."
                ) {
                    if !controller.isTrusted {
                        Button("Grant Access…") { MenuBarItems.requestAccess() }
                    }
                }
                Step(
                    systemImage: "square.grid.3x1.below.line.grid.1x2",
                    tint: .accentColor,
                    title: "Choose what to hide",
                    detail: "In Settings → Layout, drag items into Hidden or Always Hidden."
                )
                Step(
                    systemImage: "cursorarrow.click",
                    tint: .accentColor,
                    title: "Bring them back",
                    detail: revealDetail
                )
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))

            Button(action: onFinish) {
                Text(controller.isTrusted ? "Open Layout" : "Continue Without Access")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 480)
        .onReceive(trustPoll) { _ in controller.refreshTrust() }
    }

    private var revealDetail: String {
        let shortcut = Preferences.shared.revealShortcut.map { ", or press \($0.displayString)" } ?? ""
        return "Click the wand in the menu bar to show Hidden items\(shortcut). ⌥-click it to show Always Hidden items too."
    }
}

private struct Step<Accessory: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory().padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

extension Step where Accessory == EmptyView {
    init(systemImage: String, tint: Color, title: String, detail: String) {
        self.init(systemImage: systemImage, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}
