/// Apple's menu bar items that the hiding API can keep visible, by their
/// `MBSystemItemIdentifier` raw value (docs/spikes.md §1c).
enum SystemItem: Int, CaseIterable, Identifiable, Sendable {
    case battery = 0
    case bluetooth = 1
    case clock = 2
    case displays = 3
    case keyboard = 4
    case volume = 5
    case wifi = 6
    case screenMirroring = 7
    case controlCenter = 8

    var id: Int { rawValue }

    /// From the identifier MenuBarAgent gives the item in its AX tree.
    /// `com.apple.menuextra.display`, `.wifi` etc. were seen on macOS 27; the
    /// rest are best guesses, so several spellings are accepted.
    init?(menuExtraIdentifier identifier: String) {
        let prefix = "com.apple.menuextra."
        guard identifier.hasPrefix(prefix) else { return nil }
        switch identifier.dropFirst(prefix.count).lowercased() {
        case "battery": self = .battery
        case "bluetooth": self = .bluetooth
        case "clock": self = .clock
        case "display", "displays": self = .displays
        case "keyboard", "keyboardbrightness": self = .keyboard
        case "volume", "sound": self = .volume
        case "wifi", "airport": self = .wifi
        case "screenmirroring", "airplay": self = .screenMirroring
        case "controlcenter": self = .controlCenter
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .battery: "Battery"
        case .bluetooth: "Bluetooth"
        case .clock: "Clock"
        case .displays: "Display"
        case .keyboard: "Keyboard Brightness"
        case .volume: "Sound"
        case .wifi: "Wi-Fi"
        case .screenMirroring: "Screen Mirroring"
        case .controlCenter: "Control Center"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .bluetooth: "wave.3.right"
        case .clock: "clock"
        case .displays: "sun.max"
        case .keyboard: "light.max"
        case .volume: "speaker.wave.2"
        case .wifi: "wifi"
        case .screenMirroring: "rectangle.on.rectangle"
        case .controlCenter: "switch.2"
        }
    }

    /// Shown unless the user hides them: the clock and Control Center are
    /// where people look first.
    static let defaultShown: Set<SystemItem> = [.battery, .clock, .wifi, .controlCenter]
}
