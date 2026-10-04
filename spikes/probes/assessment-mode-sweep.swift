import AppKit
import ObjectiveC
dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
let cfgCls = NSClassFromString("MBAssessmentModeConfiguration") as! NSObject.Type
let asCls = NSClassFromString("MBAssessmentModeAssertion") as! NSObject.Type
typealias InitCfg = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject
typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void
func activate(system: [Int], bundles: [String]) -> NSObject {
  let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
  let alloc = cfgCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
  let cfg = unsafeBitCast(class_getMethodImplementation(cfgCls, initSel), to: InitCfg.self)(alloc, initSel, system.map { NSNumber(value: $0) } as NSArray, bundles as NSArray)
  let a = asCls.init()
  let sel = NSSelectorFromString("activateWithConfiguration:completionHandler:")
  let sem = DispatchSemaphore(value: 0)
  let handler: @convention(block) (NSError?) -> Void = { e in if let e { print("ERR \(e)") }; sem.signal() }
  unsafeBitCast(class_getMethodImplementation(asCls, sel), to: Activate.self)(a, sel, cfg, handler)
  _ = sem.wait(timeout: .now() + 2)
  return a
}
func attr<T>(_ e: AXUIElement, _ n: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v as? T : nil }
// Visible slots in MenuBarAgent's AX tree: (x, width, description)
func slots() -> [(Int, Int, String)] {
  guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
  let app = AXUIElementCreateApplication(agent.processIdentifier)
  var out: [(Int, Int, String)] = []
  for w in (attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
    for slot in (attr(w, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
      var p = CGPoint.zero, s = CGSize.zero
      if let pv: AXValue = attr(slot, kAXPositionAttribute) { AXValueGetValue(pv, .cgPoint, &p) }
      if let sv: AXValue = attr(slot, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &s) }
      guard s.width > 0 else { continue }
      let kids: [AXUIElement] = attr(slot, kAXChildrenAttribute) ?? []
      var pid: pid_t = 0
      var name = "chevron"
      if let k = kids.first {
        AXUIElementGetPid(k, &pid)
        let deeper: [AXUIElement] = attr(k, kAXChildrenAttribute) ?? []
        let id: String? = attr(k, kAXIdentifierAttribute) ?? deeper.first.flatMap { attr($0, kAXIdentifierAttribute) }
        name = id ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid\(pid)"
      }
      out.append((Int(p.x), Int(s.width), name))
    }
  }
  return out.sorted { $0.0 < $1.0 }
}
let mode = CommandLine.arguments.dropFirst().first ?? "sweep"
if mode == "baseline" {
  for s in slots() { print(s) }
} else if mode == "sweep" {
  let baseline = Set(slots().map(\.2))
  print("baseline:", baseline.sorted())
  for n in 0...16 {
    let a = activate(system: [n], bundles: [])
    Thread.sleep(forTimeInterval: 1.8)
    let t = Process(); t.launchPath = "/usr/sbin/screencapture"; t.arguments = ["-x", "-R1000,0,470,32", String(format: "/tmp/sweep/%02d.png", n)]; t.launch(); t.waitUntilExit()
    a.perform(NSSelectorFromString("invalidate"))
    Thread.sleep(forTimeInterval: 1.5)
  }
} else if mode == "crash" {
  _ = activate(system: [], bundles: ["org.p0deje.Maccy"])
  Thread.sleep(forTimeInterval: 1)
  print("exiting WITHOUT invalidate")
  exit(0)
}
