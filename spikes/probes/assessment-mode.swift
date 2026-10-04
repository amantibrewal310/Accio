import Foundation
import ObjectiveC
dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
let allowed = CommandLine.arguments.dropFirst().map { $0 }
let cfgCls = NSClassFromString("MBAssessmentModeConfiguration") as! NSObject.Type
let asCls = NSClassFromString("MBAssessmentModeAssertion") as! NSObject.Type

typealias InitCfg = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject
let cfgAlloc = cfgCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
let cfg = unsafeBitCast(class_getMethodImplementation(cfgCls, initSel), to: InitCfg.self)(cfgAlloc, initSel, [] as NSArray, allowed as NSArray)

let assertion = asCls.init()
typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void
let actSel = NSSelectorFromString("activateWithConfiguration:completionHandler:")
let done = DispatchSemaphore(value: 0)
unsafeBitCast(class_getMethodImplementation(asCls, actSel), to: Activate.self)(assertion, actSel, cfg) { err in
  print("activate completion: \(err.map { "\($0)" } ?? "success")"); done.signal()
}
print("wait:", done.wait(timeout: .now() + 3) == .success ? "completed" : "TIMEOUT")
Thread.sleep(forTimeInterval: 1.5)
let t = Process(); t.launchPath = "/usr/sbin/screencapture"; t.arguments = ["-x", "-R600,0,870,32", "/tmp/mb-assert-on.png"]; t.launch(); t.waitUntilExit()
assertion.perform(NSSelectorFromString("invalidate"))
print("invalidated")
Thread.sleep(forTimeInterval: 1.0)
let t2 = Process(); t2.launchPath = "/usr/sbin/screencapture"; t2.arguments = ["-x", "-R600,0,870,32", "/tmp/mb-assert-off.png"]; t2.launch(); t2.waitUntilExit()
