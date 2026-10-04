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

func shot(_ name: String, height: Int = 32) {
  let t = Process(); t.launchPath = "/usr/sbin/screencapture"; t.arguments = ["-x", "-R600,0,870,\(height)", "/tmp/flow-\(name).png"]; t.launch(); t.waitUntilExit()
}
func slotFrame(_ id: String, system: Bool = false) -> CGRect? {
  guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
  let app = AXUIElementCreateApplication(agent.processIdentifier)
  for w in (attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
    for slot in (attr(w, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
      guard let k = (attr(slot, kAXChildrenAttribute) as [AXUIElement]?)?.first else { continue }
      var pid: pid_t = 0; AXUIElementGetPid(k, &pid)
      if system {
        let deeper: [AXUIElement] = attr(k, kAXChildrenAttribute) ?? []
        let ident: String? = attr(k, kAXIdentifierAttribute) ?? deeper.first.flatMap { attr($0, kAXIdentifierAttribute) }
        guard ident == id else { continue }
      } else {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == id else { continue }
      }
      var p = CGPoint.zero, s = CGSize.zero
      if let pv: AXValue = attr(slot, kAXPositionAttribute) { AXValueGetValue(pv, .cgPoint, &p) }
      if let sv: AXValue = attr(slot, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &s) }
      if s.width > 0 { return CGRect(origin: p, size: s) }
    }
  }
  return nil
}
func click(_ r: CGRect) {
  let c = CGPoint(x: r.midX, y: r.midY)
  let saved = CGEvent(source: nil)!.location
  let src = CGEventSource(stateID: .hidSystemState)
  CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap)
  usleep(50_000)
  CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap)
  CGWarpMouseCursorPosition(saved)
}
func escape() {
  let src = CGEventSource(stateID: .hidSystemState)
  CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)!.post(tap: .cghidEventTap)
  CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
}

let maccy = "org.p0deje.Maccy"
let settle = 1.8
// (a) union or latest-wins? A = clock, B = Maccy only, both active.
let a = activate(system: [2], bundles: [])
let b = activate(system: [], bundles: [maccy])
Thread.sleep(forTimeInterval: settle); shot("a-union")
a.perform(NSSelectorFromString("invalidate")); b.perform(NSSelectorFromString("invalidate"))
Thread.sleep(forTimeInterval: 1.2)
// (b) Focus candidates
let f = activate(system: [], bundles: ["com.apple.MenuBarAgent", "com.apple.focus", "com.apple.donotdisturbd", "com.apple.Focus", "com.apple.systemuiserver", "com.apple.menuextra.focusmode"])
Thread.sleep(forTimeInterval: settle); shot("b-focus")
f.perform(NSSelectorFromString("invalidate"))
Thread.sleep(forTimeInterval: 1.2)
// (c) AXPress on Maccy via its own AXExtrasMenuBar, cursor untouched
let hidden = activate(system: [2], bundles: [maccy])
Thread.sleep(forTimeInterval: settle)
let before = CGEvent(source: nil)!.location
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: maccy).first,
   let extras: AXUIElement = attr(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar"),
   let item = (attr(extras, kAXChildrenAttribute) as [AXUIElement]?)?.first {
  let t = Date()
  let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
  print("AXPress Maccy -> \(err.rawValue) in \(Int(Date().timeIntervalSince(t)*1000)) ms; cursor moved: \(CGEvent(source: nil)!.location != before)")
  Thread.sleep(forTimeInterval: 0.8); shot("c-axpress", height: 300); escape()
} else { print("Maccy AX item not found") }
Thread.sleep(forTimeInterval: 0.6)
// (d) CGEvent click on a system item (Wi-Fi) located via its identifier
let wifiShown = activate(system: [2, 6], bundles: [maccy])
hidden.perform(NSSelectorFromString("invalidate"))
Thread.sleep(forTimeInterval: settle)
if let w = slotFrame("com.apple.menuextra.wifi", system: true) {
  print("wifi slot \(w)"); click(w); Thread.sleep(forTimeInterval: 1.0); shot("d-wifi", height: 420); escape()
} else { print("wifi slot NOT FOUND") }
Thread.sleep(forTimeInterval: 0.6)
wifiShown.perform(NSSelectorFromString("invalidate"))
Thread.sleep(forTimeInterval: settle); shot("e-none")
print("done")
