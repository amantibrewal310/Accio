import AppKit
import CoreGraphics

// MARK: - Private CoreGraphics (SkyLight) API

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
func CGSGetWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: UnsafeMutablePointer<Int32>
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: UnsafeMutablePointer<Int32>
) -> CGError

// MARK: - Model

struct MenuBarWindow {
    let windowID: CGWindowID
    /// Global coordinates, origin at the top-left of the primary display.
    let frame: CGRect
    let layer: Int
    let ownerPID: pid_t
    let ownerName: String
    /// Only populated when the process has Screen Recording permission.
    let title: String?
    let isOnScreen: Bool

    var bundleID: String? {
        NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }

    init?(_ info: [String: Any]) {
        guard
            let number = info[kCGWindowNumber as String] as? CGWindowID,
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            let pid = info[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        windowID = number
        frame = bounds
        layer = info[kCGWindowLayer as String] as? Int ?? -1
        ownerPID = pid
        ownerName = info[kCGWindowOwnerName as String] as? String ?? "?"
        title = info[kCGWindowName as String] as? String
        isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

// MARK: - Queries

enum WindowServer {
    /// Status item windows of every process, via the private SkyLight call
    /// Ice and Bartender are believed to use. Order is as returned.
    static func privateMenuBarWindowIDs() -> [CGWindowID] {
        let cid = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(cid, 0, &count) == .success, count > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        var realCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(cid, 0, count, &list, &realCount) == .success else { return [] }
        return Array(list.prefix(Int(realCount)))
    }

    static func describe(_ ids: [CGWindowID]) -> [MenuBarWindow] {
        guard !ids.isEmpty else { return [] }
        let pointers = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: ids.count)
        defer { pointers.deallocate() }
        for (i, id) in ids.enumerated() {
            pointers[i] = UnsafeRawPointer(bitPattern: UInt(id))
        }
        guard
            let array = CFArrayCreate(kCFAllocatorDefault, pointers, ids.count, nil),
            let infos = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [] }
        return infos.compactMap(MenuBarWindow.init)
    }

    /// Menu bar item windows found through the private API.
    static func privateItems() -> [MenuBarWindow] {
        describe(privateMenuBarWindowIDs()).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Status-level windows through the public API, for comparison.
    static func publicStatusWindows() -> [MenuBarWindow] {
        guard let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos
            .compactMap(MenuBarWindow.init)
            .filter { $0.layer == Int(CGWindowLevelForKey(.statusWindow)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Items owned by one process, left to right.
    static func items(ownedBy pid: pid_t) -> [MenuBarWindow] {
        privateItems().filter { $0.ownerPID == pid }
    }
}

// MARK: - Helpers

func residentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func ms(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let millis = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.1f ms", millis)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func printTable(_ windows: [MenuBarWindow]) {
    print(pad("wid", 7), pad("x", 7), pad("w", 5), pad("on", 3), pad("pid", 6), pad("owner", 22), pad("bundle", 34), "title")
    for w in windows {
        print(
            pad(String(w.windowID), 7),
            pad(String(Int(w.frame.minX)), 7),
            pad(String(Int(w.frame.width)), 5),
            pad(w.isOnScreen ? "y" : "n", 3),
            pad(String(w.ownerPID), 6),
            pad(w.ownerName, 22),
            pad(w.bundleID ?? "-", 34),
            w.title ?? "<nil>"
        )
    }
}
