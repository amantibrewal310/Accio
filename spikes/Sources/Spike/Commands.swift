import AppKit

@MainActor
enum Commands {
    // MARK: perms

    static func perms(_ args: Args) {
        if args.flag("prompt") {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestScreenCaptureAccess()
        }
        print("Accessibility:    \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")")
    }

    // MARK: list (spike 2)

    static func list(_ args: Args) {
        var start = ContinuousClock.now
        let privateItems = WindowServer.privateItems()
        print("== Private CGSGetProcessMenuBarWindowList: \(privateItems.count) windows in \(ms(since: start))")
        printTable(privateItems)

        start = ContinuousClock.now
        let publicItems = WindowServer.publicStatusWindows()
        print("\n== Public CGWindowListCopyWindowInfo, layer == statusWindow: \(publicItems.count) windows in \(ms(since: start))")
        printTable(publicItems)

        let owners = Set(privateItems.map(\.ownerName))
        print("\nDistinct owners (private list): \(owners.count) -> \(owners.sorted().joined(separator: ", "))")
        print(String(format: "RSS: %.1f MB", residentMemoryMB()))
    }

    // MARK: ax (spike 2b)

    static func ax(_ args: Args) {
        if args.flag("timing") {
            var rows: [(Duration, String)] = []
            for app in NSWorkspace.shared.runningApplications {
                let start = ContinuousClock.now
                let n = AX.items(of: app).count
                rows.append((ContinuousClock.now - start, "\(app.localizedName ?? "?") policy=\(app.activationPolicy.rawValue) items=\(n)"))
            }
            for (d, s) in rows.sorted(by: { $0.0 > $1.0 }).prefix(15) { print(d, s) }
            return
        }
        if let pid = args.int("pid") {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return print("no pid \(pid)") }
            printAXTable(AX.items(of: app))
            return
        }
        let start = ContinuousClock.now
        let items = args.flag("parallel") ? AX.allItemsParallel() : AX.allItems()
        print("== AXExtrasMenuBar across \(NSWorkspace.shared.runningApplications.count) apps: \(items.count) items in \(ms(since: start))")
        printAXTable(items)
        print(String(format: "RSS: %.1f MB", residentMemoryMB()))
    }

    // MARK: notch (spike 6)

    static func notch(_ args: Args) {
        guard let primary = NSScreen.screens.first else { return print("no screens") }
        for screen in NSScreen.screens {
            print("== \(screen.localizedName)  frame=\(screen.frame)  scale=\(screen.backingScaleFactor)")
            print("   safeAreaInsets.top=\(screen.safeAreaInsets.top)")
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
                print("   no notch")
                continue
            }
            // AppKit coordinates (bottom-left origin) -> global CG (top-left origin).
            let gap = NSRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
            let cgGap = CGRect(
                x: screen.frame.minX + gap.minX,
                y: primary.frame.maxY - (screen.frame.minY + gap.maxY),
                width: gap.width,
                height: gap.height
            )
            print("   left=\(left)  right=\(right)")
            print("   notch (global CG coords) = \(cgGap)")
            let hidden = WindowServer.privateItems().filter { $0.frame.intersects(cgGap) }
            print("   items intersecting the notch: \(hidden.count)")
            printTable(hidden)
        }
    }

    // MARK: dummies (test fixture; --divider is spike 1)

    static func dummies(_ args: Args) async {
        let count = args.int("count") ?? 3
        let target = ClickLogger()
        var items: [NSStatusItem] = []
        var signalSources: [DispatchSourceSignal] = []
        if args.flag("divider") {
            // Created first so D1..DN land to its left. SIGUSR1 expands it
            // (hiding D1..DN), SIGUSR2 collapses it again.
            let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            divider.button?.title = "‖"
            items.append(divider)
            for (sig, length) in [(SIGUSR1, 10_000.0), (SIGUSR2, NSStatusItem.variableLength)] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        divider.length = length
                        print("divider length = \(length)")
                        fflush(stdout)
                    }
                }
                source.resume()
                signalSources.append(source)
            }
        }
        for i in 1...count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "D\(i)"
            item.button?.target = target
            item.button?.action = #selector(ClickLogger.clicked(_:))
            items.append(item)
        }
        try? await Task.sleep(for: .milliseconds(800))
        print("dummies pid=\(getpid())")
        fflush(stdout)
        if let cycle = args.int("cycle"), let divider = items.first, args.flag("divider") {
            // Human-watchable divider test: alternate every `cycle` seconds.
            let total = args.int("seconds") ?? 24
            var hidden = false
            for _ in 0..<max(total / cycle, 1) {
                print(hidden
                    ? "▶ NOW: divider COLLAPSED  → D1 D2 D3 should be VISIBLE"
                    : "▶ NOW: divider EXPANDED   → D1 D2 D3 should be GONE")
                fflush(stdout)
                divider.length = hidden ? NSStatusItem.variableLength : 10_000
                hidden.toggle()
                try? await Task.sleep(for: .seconds(cycle))
            }
            divider.length = NSStatusItem.variableLength
            print("done")
            withExtendedLifetime((items, target, signalSources)) {}
            return
        }
        try? await Task.sleep(for: .seconds(args.int("seconds") ?? 120))
        withExtendedLifetime((items, target, signalSources)) {}
    }

    // MARK: click (spike 4)

    static func click(_ args: Args) async throws {
        let window = try pick(args)
        let delivery = Synth.Delivery(rawValue: args.string("delivery") ?? "pid") ?? .pid
        print("clicking wid=\(window.windowID) owner=\(window.ownerName) x=\(Int(window.frame.minX)) via \(delivery.rawValue)")
        let start = ContinuousClock.now
        await Synth.click(window, delivery: delivery)
        print("posted in \(ms(since: start)); check the target for a reaction")
    }

    // MARK: move (spike 5)

    /// Rotation test: repeatedly ⌘-drag the rightmost of a process's items to
    /// the left of its leftmost item, verifying each move by re-reading frames.
    static func move(_ args: Args) async throws {
        guard let pid = args.int("pid").map(pid_t.init) else { throw SpikeError("--pid required") }
        let runs = args.int("repeat") ?? 10
        let steps = args.int("steps") ?? 8
        var ok = 0
        var total: Duration = .zero
        for run in 1...runs {
            let items = WindowServer.items(ownedBy: pid)
            guard items.count >= 2, let first = items.first, let last = items.last else {
                throw SpikeError("need at least 2 items owned by \(pid)")
            }
            let start = ContinuousClock.now
            await Synth.commandDrag(last, toLeftOf: first, steps: steps)
            let moved = await waitUntil(timeout: .seconds(1)) {
                WindowServer.items(ownedBy: pid).first?.windowID == last.windowID
            }
            let elapsed = ContinuousClock.now - start
            total += elapsed
            if moved { ok += 1 }
            print("run \(run): \(moved ? "ok  " : "FAIL") wid \(last.windowID) in \(ms(since: start))")
            try? await Task.sleep(for: .milliseconds(150))
        }
        print("\n\(ok)/\(runs) moves succeeded, avg \(total / runs)")
    }

    // MARK: capture (spike 3)

    static func capture(_ args: Args) async throws {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let dir = URL(fileURLWithPath: "/tmp/accio-spike", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let targets: [MenuBarWindow]
        if args.flag("all") {
            targets = WindowServer.privateItems().filter(\.isOnScreen)
        } else {
            targets = [try pick(args)]
        }
        let rssBefore = residentMemoryMB()
        let allStart = ContinuousClock.now
        var failures = 0
        for window in targets {
            let start = ContinuousClock.now
            do {
                let image = try await Capture.image(of: window.windowID, scale: scale)
                let url = dir.appendingPathComponent("\(window.windowID)-\(window.ownerName).png")
                try Capture.writePNG(image, to: url)
                print("wid \(window.windowID) \(pad(window.ownerName, 22)) \(image.width)x\(image.height) in \(ms(since: start))")
            } catch {
                failures += 1
                print("wid \(window.windowID) \(pad(window.ownerName, 22)) FAILED: \(error)")
            }
        }
        print("\n\(targets.count - failures)/\(targets.count) captured in \(ms(since: allStart)) -> \(dir.path)")
        print(String(format: "RSS %.1f MB -> %.1f MB", rssBefore, residentMemoryMB()))
    }

    // MARK: helpers

    /// Resolve `--wid W` or `--pid P --index I` (left to right) to a window.
    static func pick(_ args: Args) throws -> MenuBarWindow {
        let all = WindowServer.privateItems()
        if let wid = args.int("wid") {
            guard let w = all.first(where: { $0.windowID == CGWindowID(wid) }) else { throw SpikeError("no menu bar window \(wid)") }
            return w
        }
        if let pid = args.int("pid") {
            let owned = all.filter { $0.ownerPID == pid_t(pid) }
            let index = args.int("index") ?? 0
            guard owned.indices.contains(index) else { throw SpikeError("pid \(pid) has \(owned.count) items") }
            return owned[index]
        }
        throw SpikeError("pass --wid W or --pid P [--index I]")
    }

    static func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
final class ClickLogger: NSObject {
    @objc func clicked(_ sender: NSStatusBarButton) {
        print("CLICKED \(sender.title) at \(Date().timeIntervalSince1970)")
        fflush(stdout)
    }
}
