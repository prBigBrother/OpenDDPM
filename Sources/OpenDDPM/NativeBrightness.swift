import Foundation
import CoreGraphics
import Darwin

protocol NativeBrightnessControlling {
    func supports(_ displayID: UInt32) -> Bool
    func read(_ displayID: UInt32) throws -> Int
    func readPrecise(_ displayID: UInt32) throws -> Double
    func write(_ value: Int, displayID: UInt32) throws
}

extension NativeBrightnessControlling {
    func readPrecise(_ displayID: UInt32) throws -> Double { Double(try read(displayID)) }
}

/// Dynamically loaded system brightness path, also used for native brightness
/// keys. Unsupported displays continue through the existing DDC transport.
final class NativeBrightnessBridge: NativeBrightnessControlling {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let canChange: CanChange?
    private let get: Get?
    private let set: Set?

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        handle = library
        canChange = library.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: CanChange.self) }
        get = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        set = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    }
    deinit { if let handle { dlclose(handle) } }
    func supports(_ displayID: UInt32) -> Bool {
        CGDisplayIsOnline(displayID) != 0 && CGDisplayIsBuiltin(displayID) == 0 && get != nil && set != nil && canChange?(displayID) == true
    }
    func read(_ displayID: UInt32) throws -> Int { Int(try readPrecise(displayID).rounded()) }
    func readPrecise(_ displayID: UInt32) throws -> Double {
        guard supports(displayID), let get else { throw ControlError.message("Native brightness is unavailable for the selected monitor.") }
        var value: Float = -1
        let result = get(displayID, &value)
        guard result == 0, value.isFinite, (0...1).contains(value) else {
            throw ControlError.message("macOS could not read the selected monitor’s brightness (\(result)).")
        }
        return Double(value) * 100
    }
    func write(_ value: Int, displayID: UInt32) throws {
        guard (0...100).contains(value), supports(displayID), let set else { throw ControlError.message("Native brightness is unavailable for the selected monitor.") }
        let result = set(displayID, Float(value) / 100)
        guard result == 0 else { throw ControlError.message("macOS could not set the selected monitor’s brightness (\(result)).") }
    }
}
