import Foundation
import ObjectiveC
import Security

/// Hides menu bar items with macOS 27's private assessment-mode ("exam mode")
/// assertion from MenuBarClientCore: while an assertion is active, only the
/// allow-listed apps and system items stay visible.
///
/// This is the only file that touches the private API, so a fallback (spacer
/// items) can replace it if Apple closes it. See docs/spikes.md §1b.
///
/// - Active assertions combine as a union, so a change activates the new
///   assertion first and only then invalidates the old one (no flash).
/// - The system releases the assertion if Accio dies, so a crash can't leave
///   items hidden.
@MainActor
final class MenuBarHider {
    struct AllowList: Equatable {
        var bundleIDs: Set<String>
        var systemItems: Set<SystemItem>
    }

    private typealias InitConfiguration = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject
    private typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let initSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    private let configurationClass: NSObject.Type
    private let assertionClass: NSObject.Type
    private var current: NSObject?
    private(set) var allowList: AllowList?
    /// Assertions whose activation hasn't completed yet.
    private var activating: Set<ObjectIdentifier> = []
    private var releasedWhileActivating: Set<ObjectIdentifier> = []

    /// `nil` when this macOS doesn't have the API (or has changed it).
    init?() {
        guard
            dlopen(Self.frameworkPath, RTLD_NOW) != nil,
            let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
            let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
            configurationClass.instancesRespond(to: Self.initSelector),
            assertionClass.instancesRespond(to: Self.activateSelector),
            assertionClass.instancesRespond(to: Self.invalidateSelector)
        else { return nil }
        self.configurationClass = configurationClass
        self.assertionClass = assertionClass
    }

    var isHiding: Bool { current != nil }

    /// MenuBarAgent ignores allow-listed bundle IDs of apps without a team
    /// signature (ad-hoc builds), so an unsigned Accio hides its own icon too.
    nonisolated static let keepsOwnIconVisible: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard
            SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    /// Show only `allowList`. Does nothing if that's already in effect.
    func hide(allowing allowList: AllowList) {
        guard allowList != self.allowList || current == nil else { return }
        let previous = current
        let assertion = makeAssertion(allowList)
        current = assertion
        self.allowList = allowList
        let id = ObjectIdentifier(assertion)
        activating.insert(id)
        activate(assertion) { [weak self] error in
            if let error { log("[Hider] activate failed: \(error)") }
            guard let self else { return }
            self.activating.remove(id)
            // Released while activating: release again in case activation landed afterwards.
            if self.releasedWhileActivating.remove(id) != nil { assertion.perform(Self.invalidateSelector) }
            // Release the old assertion only once the new one holds.
            previous.map(self.invalidate)
        }
    }

    /// Show everything.
    func showAll() {
        current.map(invalidate)
        current = nil
        allowList = nil
    }

    /// Re-create the assertion, e.g. after MenuBarAgent restarted and forgot it.
    func reassert() {
        guard let allowList, current != nil else { return }
        self.allowList = nil
        hide(allowing: allowList)
    }

    private func makeAssertion(_ allowList: AllowList) -> NSObject {
        let systemItems = allowList.systemItems.map { NSNumber(value: $0.rawValue) } as NSArray
        let bundleIDs = Array(allowList.bundleIDs) as NSArray
        let alloc = configurationClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let initialize = unsafeBitCast(
            class_getMethodImplementation(configurationClass, Self.initSelector), to: InitConfiguration.self
        )
        let configuration = initialize(alloc, Self.initSelector, systemItems, bundleIDs)
        let assertion = assertionClass.init()
        // Kept on the assertion until activation, which takes it as an argument.
        objc_setAssociatedObject(assertion, &Self.configurationKey, configuration, .OBJC_ASSOCIATION_RETAIN)
        return assertion
    }

    private static var configurationKey: UInt8 = 0

    private func activate(_ assertion: NSObject, completion: @escaping @MainActor (NSError?) -> Void) {
        guard let configuration = objc_getAssociatedObject(assertion, &Self.configurationKey) else { return }
        // Must be a stored block: passing a closure literal makes it non-escaping and crashes.
        let handler: @convention(block) (NSError?) -> Void = { error in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
        let activate = unsafeBitCast(
            class_getMethodImplementation(assertionClass, Self.activateSelector), to: Activate.self
        )
        activate(assertion, Self.activateSelector, configuration as AnyObject, handler)
    }

    private func invalidate(_ assertion: NSObject) {
        let id = ObjectIdentifier(assertion)
        if activating.contains(id) { releasedWhileActivating.insert(id) }
        assertion.perform(Self.invalidateSelector)
    }
}
