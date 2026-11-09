import AppKit
import CoreGraphics
import ObjectiveC

/// Optional compatibility bridge matching DDPM's MPDisplay HDR preference path.
/// MonitorPanel is private: check every selector and ABI before invoking it.
/// The readback confirms the macOS preference, not physical HDR output.
@MainActor
final class MonitorHDR: ObservableObject {
    @Published private(set) var supported = false
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var error: String?
    private var displayID: CGDirectDisplayID?
    private var operationID = UUID()

    func refresh(displayID: CGDirectDisplayID?) {
        self.displayID = displayID
        guard let displayID, CGDisplayIsOnline(displayID) != 0 else {
            supported = false
            unavailableReason = "HDR is unavailable while the selected monitor is disconnected."
            return
        }
        do {
            let bridge = try HDRDisplayBridge(displayID: displayID)
            supported = true
            enabled = bridge.hasHDRModes && bridge.preferHDRModes
            unavailableReason = bridge.hasHDRModes ? nil : "HDR is not currently advertised. Enabling it will ask the monitor and macOS to negotiate HDR."
        } catch {
            supported = false
            unavailableReason = error.localizedDescription
        }
    }

    func setEnabled(_ desired: Bool, prepare: @escaping (Bool) async throws -> Void = { _ in }) async {
        guard !busy, supported, let displayID else { return }
        busy = true; error = nil
        let request = UUID(); operationID = request
        defer { if operationID == request { busy = false } }
        var previous: Bool?
        var bridgeForRollback: HDRDisplayBridge?
        do {
            let bridge = try HDRDisplayBridge(displayID: displayID)
            previous = bridge.preferHDRModes
            bridgeForRollback = bridge
            try await prepare(desired)
            guard self.displayID == displayID else { throw HDRBridgeError.unavailable("The selected monitor changed during HDR configuration.") }
            if desired {
                var available = false
                for _ in 0..<60 {
                    let refreshed = try HDRDisplayBridge(displayID: displayID)
                    if refreshed.hasHDRModes { available = true; break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                guard available else { throw HDRBridgeError.unavailable("HDR is unavailable for the current cable or display mode.") }
            }
            let currentBridge = try HDRDisplayBridge(displayID: displayID)
            currentBridge.preferHDRModes = desired
            // Display reconfiguration can lag behind the preference setter.
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard self.displayID == displayID, operationID == request else { throw HDRBridgeError.unavailable("The selected monitor changed during HDR configuration.") }
                let readback = try HDRDisplayBridge(displayID: displayID)
                if readback.preferHDRModes == desired && (!desired || readback.hasHDRModes) {
                    refresh(displayID: displayID)
                    return
                }
            }
            throw HDRBridgeError.unavailable("macOS did not confirm the HDR preference. Refresh display settings and retry.")
        } catch {
            var message = error.localizedDescription
            if let previous, let bridgeForRollback {
                do { try await prepare(previous) }
                catch { message += " Restoring the monitor HDR setting failed: \(error.localizedDescription)" }
                bridgeForRollback.preferHDRModes = previous
                if bridgeForRollback.preferHDRModes != previous { message += " macOS did not confirm HDR rollback." }
            }
            self.error = message
            if self.displayID == displayID { refresh(displayID: displayID) }
        }
    }
}

private enum HDRBridgeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(reason) = self { return reason }; return nil }
}

private final class HDRDisplayBridge {
    private let object: AnyObject
    private let supportedGetter: IMP
    private let enabledGetter: IMP
    private let enabledSetter: IMP
    private static let framework = Bundle(path: "/System/Library/PrivateFrameworks/MonitorPanel.framework")

    init(displayID: CGDirectDisplayID) throws {
        guard Self.framework?.load() == true, let cls = NSClassFromString("MPDisplay") else {
            throw HDRBridgeError.unavailable("The macOS HDR compatibility interface is unavailable on this system.")
        }
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
        let supportedSelector = NSSelectorFromString("hasHDRModes")
        let enabledSelector = NSSelectorFromString("preferHDRModes")
        let setterSelector = NSSelectorFromString("setPreferHDRModes:")
        guard let allocation = class_getClassMethod(cls, allocSelector),
              let initialization = class_getInstanceMethod(cls, initSelector),
              let supported = class_getInstanceMethod(cls, supportedSelector),
              let enabled = class_getInstanceMethod(cls, enabledSelector),
              let setter = class_getInstanceMethod(cls, setterSelector),
              Self.matches(allocation, returns: ["@"], arguments: []),
              Self.matches(initialization, returns: ["@"], arguments: [["i", "I"]]),
              Self.matches(supported, returns: ["B", "c"], arguments: []),
              Self.matches(enabled, returns: ["B", "c"], arguments: []),
              Self.matches(setter, returns: ["v"], arguments: [["B", "c"]]) else {
            throw HDRBridgeError.unavailable("The macOS HDR interface changed. This version of OpenDDPM cannot safely control it.")
        }
        typealias Allocate = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?
        let allocate = unsafeBitCast(method_getImplementation(allocation), to: Allocate.self)
        let initialize = unsafeBitCast(method_getImplementation(initialization), to: Initialize.self)
        let allocated = allocate(cls as AnyObject, allocSelector)
        guard let initialized = initialize(allocated.takeUnretainedValue(), initSelector, displayID) else {
            throw HDRBridgeError.unavailable("macOS could not open the selected display's HDR interface.")
        }
        object = initialized.takeRetainedValue()
        supportedGetter = method_getImplementation(supported)
        enabledGetter = method_getImplementation(enabled)
        enabledSetter = method_getImplementation(setter)
    }

    var hasHDRModes: Bool { readBool(supportedGetter, selector: "hasHDRModes") }
    var preferHDRModes: Bool {
        get { readBool(enabledGetter, selector: "preferHDRModes") }
        set {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(enabledSetter, to: Setter.self)(object, NSSelectorFromString("setPreferHDRModes:"), newValue)
        }
    }
    private func readBool(_ implementation: IMP, selector: String) -> Bool {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(object, NSSelectorFromString(selector))
    }
    private static func matches(_ method: Method, returns: Set<String>, arguments: [Set<String>]) -> Bool {
        guard method_getNumberOfArguments(method) == UInt32(arguments.count + 2) else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard returns.contains(String(cString: returnType)) else { return false }
        for (index, accepted) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index + 2)) else { return false }
            defer { free(type) }
            guard accepted.contains(String(cString: type)) else { return false }
        }
        return true
    }
}
