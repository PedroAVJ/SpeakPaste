import Darwin
import ObjectiveC.runtime
import UIKit

struct HostApplicationResolver {
    func bundleIdentifier(for controller: UIInputViewController) -> String? {
        if let legacyIdentifier = legacyBundleIdentifier(for: controller) {
            return legacyIdentifier
        }
        guard let processID = hostProcessIdentifier(for: controller) else {
            return nil
        }
        return bundleIdentifier(forProcessID: processID)
    }

    private func legacyBundleIdentifier(
        for controller: UIInputViewController
    ) -> String? {
        let selector = NSSelectorFromString("_hostApplicationBundleIdentifier")
        guard controller.responds(to: selector) else { return nil }
        return controller.perform(selector)?.takeUnretainedValue() as? String
    }

    private func hostProcessIdentifier(
        for controller: UIInputViewController
    ) -> Int32? {
        let selector = NSSelectorFromString("_hostProcessIdentifier")
        guard controller.responds(to: selector) else { return nil }
        typealias ProcessIdentifierFunction = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = controller.method(for: selector)
        let function = unsafeBitCast(
            implementation,
            to: ProcessIdentifierFunction.self
        )
        let processID = function(controller, selector)
        return processID > 0 ? processID : nil
    }

    private func bundleIdentifier(forProcessID processID: Int32) -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSCopyDisplayIdentifierForProcessID") else {
            return nil
        }

        typealias BundleIdentifierFunction = @convention(c) (Int32) -> Unmanaged<CFString>?
        let function = unsafeBitCast(symbol, to: BundleIdentifierFunction.self)
        guard let identifier = function(processID)?.takeRetainedValue() else {
            return nil
        }
        return identifier as String
    }
}
