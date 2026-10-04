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

// Slots owned by one pid, left to right, deduplicated across MenuBarAgent's windows.
func slots(pid target: pid_t) -> [CGRect] {
  guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
  let app = AXUIElementCreateApplication(agent.processIdentifier)
  var seen = Set<Int>(); var out: [CGRect] = []
  for w in (attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
    for slot in (attr(w, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
      guard let k = (attr(slot, kAXChildrenAttribute) as [AXUIElement]?)?.first else { continue }
      var pid: pid_t = 0; AXUIElementGetPid(k, &pid)
      guard pid == target else { continue }
      var p = CGPoint.zero, s = CGSize.zero
      if let pv: AXValue = attr(slot, kAXPositionAttribute) { AXValueGetValue(pv, .cgPoint, &p) }
      if let sv: AXValue = attr(slot, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &s) }
      guard s.width > 0, seen.insert(Int(p.x)).inserted else { continue }
      out.append(CGRect(origin: p, size: s))
    }
  }
  return out.sorted { $0.minX < $1.minX }
}
// Item titles in on-screen order, read from the owning process's AXExtrasMenuBar.
func order(pid: pid_t) -> [String] {
  let app = AXUIElementCreateApplication(pid)
  guard let extras: AXUIElement = attr(app, "AXExtrasMenuBar"), let kids: [AXUIElement] = attr(extras, kAXChildrenAttribute) else { return [] }
  return kids.compactMap { k -> (CGFloat, String)? in
    var p = CGPoint.zero
    guard let pv: AXValue = attr(k, kAXPositionAttribute) else { return nil }
    AXValueGetValue(pv, .cgPoint, &p)
    return (p.x, (attr(k, kAXTitleAttribute) as String?) ?? "?")
  }.sorted { $0.0 < $1.0 }.map(\.1)
}
func ev(_ t: CGEventType, _ p: CGPoint, cmd: Bool) {
  let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
  if cmd { e.flags = .maskCommand }
  e.post(tap: .cghidEventTap)
}
func cmdDrag(from a: CGRect, toLeftOf b: CGRect, steps: Int, stepMs: UInt32) {
  let start = CGPoint(x: a.midX, y: a.midY), end = CGPoint(x: b.minX + 3, y: b.midY)
  let saved = CGEvent(source: nil)!.location
  ev(.leftMouseDown, start, cmd: true); usleep(60_000)
  for i in 1...steps { let t = CGFloat(i) / CGFloat(steps); ev(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), cmd: true); usleep(stepMs * 1000) }
  ev(.leftMouseUp, end, cmd: true)
  CGWarpMouseCursorPosition(saved)
}
let pid = pid_t(CommandLine.arguments[1])!
let runs = Int(CommandLine.arguments[2]) ?? 10
let steps = Int(CommandLine.arguments[3]) ?? 12
let stepMs = UInt32(CommandLine.arguments[4]) ?? 30
print("start order:", order(pid: pid))
var ok = 0; var total = 0.0
for run in 1...runs {
  let s = slots(pid: pid)
  let before = order(pid: pid)
  guard s.count >= 2, let last = before.last else { print("only \(s.count) slots"); break }
  let t = Date()
  cmdDrag(from: s.last!, toLeftOf: s.first!, steps: steps, stepMs: stepMs)
  var moved = false
  while Date().timeIntervalSince(t) < 2 { if order(pid: pid).first == last { moved = true; break }; usleep(20_000) }
  let dt = Date().timeIntervalSince(t) * 1000; total += dt
  if moved { ok += 1 }
  print("run \(run): \(moved ? "ok  " : "FAIL") \(before) -> \(order(pid: pid)) in \(Int(dt)) ms")
  usleep(250_000)
}
print("\n\(ok)/\(runs) succeeded, avg \(Int(total / Double(runs))) ms (steps=\(steps), stepMs=\(stepMs))")
