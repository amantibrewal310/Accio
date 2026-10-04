import Foundation
let h = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
typealias Accessor = @convention(c) (Int) -> UnsafeRawPointer
let acc = unsafeBitCast(dlsym(h, "$s17MenuBarClientCore22MBSystemItemIdentifierOMa")!, to: Accessor.self)
let type = unsafeBitCast(acc(0), to: Any.Type.self)
print("type:", type)
guard let iterable = type as? any CaseIterable.Type else { fatalError("not CaseIterable") }
func dump<T: CaseIterable>(_ t: T.Type) {
  for c in T.allCases {
    let raw = (c as? any RawRepresentable).map { "\($0.rawValue)" } ?? "?"
    print(raw, String(describing: c))
  }
}
dump(iterable)
