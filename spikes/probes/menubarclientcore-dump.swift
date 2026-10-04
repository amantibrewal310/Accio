import Foundation
import ObjectiveC
guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil else { fatalError(String(cString: dlerror())) }
for name in ["MBAssessmentModeAssertion", "MBAssessmentModeConfiguration", "MBMenuBarItemManager"] {
  guard let cls: AnyClass = NSClassFromString(name) else { print("no class \(name)"); continue }
  print("== \(name) : \(class_getSuperclass(cls).map(NSStringFromClass) ?? "-")")
  for c in [cls, object_getClass(cls)!] {
    var n: UInt32 = 0
    if let ms = class_copyMethodList(c, &n) { for i in 0..<Int(n) { print("  \(c === cls ? "-" : "+") \(NSStringFromSelector(method_getName(ms[i]))) \(String(cString: method_getTypeEncoding(ms[i])!))") } }
  }
  var n: UInt32 = 0
  if let ps = class_copyPropertyList(cls, &n) { for i in 0..<Int(n) { print("  @property \(String(cString: property_getName(ps[i]))) \(String(cString: property_getAttributes(ps[i])!))") } }
}
