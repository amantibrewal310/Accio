import AppKit

let usage = """
usage: spike <command> [options]

  perms    [--prompt]                       Accessibility / Screen Recording status
  list                                      enumerate menu bar item windows (spike 2)
  ax                                        enumerate items via Accessibility (spike 2b)
  notch                                     notch geometry + items behind it (spike 6)
  dummies  [--count N] [--seconds S] [--divider]
           spawn test items D1..DN, log clicks; --divider adds a divider
           toggled by SIGUSR1 (expand) / SIGUSR2 (collapse) (spike 1)
  click    (--wid W | --pid P --index I) [--delivery pid|hid]   synthetic click (spike 4)
  move     --pid P [--repeat R] [--steps N] ⌘-drag rotation test (spike 5)
  capture  (--all | --wid W | --pid P --index I)                ScreenCaptureKit images (spike 3)
"""

struct Args {
    let command: String
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        command = argv.first ?? ""
        var i = 1
        while i < argv.count {
            let key = argv[i].replacingOccurrences(of: "--", with: "")
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                values[key] = argv[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    do {
        switch args.command {
        case "perms": Commands.perms(args)
        case "list": Commands.list(args)
        case "ax": Commands.ax(args)
        case "notch": Commands.notch(args)
        case "dummies": await Commands.dummies(args)
        case "click": try await Commands.click(args)
        case "move": try await Commands.move(args)
        case "capture": try await Commands.capture(args)
        default:
            print(usage)
            exit(2)
        }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
app.run()
