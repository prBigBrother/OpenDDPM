import Foundation
import CoreGraphics
import Darwin

@MainActor
protocol BrightnessChangeNotifying: AnyObject {
    func events(displayID: UInt32) -> AsyncStream<Void>?
}

/// One system registration per display, shared by the settings page and menu.
/// The callback is only a signal: values are read through the serial-bound engine.
@MainActor
final class NativeBrightnessNotifications: BrightnessChangeNotifying {
    static let shared = NativeBrightnessNotifications()
    private typealias Register = @convention(c) (UInt32, UInt32, CFNotificationCallback?) -> Int32
    private typealias Unregister = @convention(c) (UInt32, UInt32) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let register: Register?
    private let unregister: Unregister?
    private struct Entry {
        let displayID: UInt32
        let continuation: AsyncStream<Void>.Continuation
    }
    private var entries: [UUID: Entry] = [:]
    private var registered = Set<UInt32>()
    private static let callback: CFNotificationCallback = { _, _, _, _, _ in
        DispatchQueue.main.async { NativeBrightnessNotifications.shared.signal() }
    }
    private init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        handle = library
        register = library.flatMap { dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") }.map { unsafeBitCast($0, to: Register.self) }
        unregister = library.flatMap { dlsym($0, "DisplayServicesUnregisterForBrightnessChangeNotifications") }.map { unsafeBitCast($0, to: Unregister.self) }
    }
    func events(displayID: UInt32) -> AsyncStream<Void>? {
        guard let register, unregister != nil else { return nil }
        if !registered.contains(displayID) {
            guard register(displayID, displayID, Self.callback) == 0 else { return nil }
            registered.insert(displayID)
        }
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            entries[token] = Entry(displayID: displayID, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.remove(token) }
            }
            continuation.yield(())
        }
    }
    private func signal() {
        // Callback payload details are private. Reread each active target rather
        // than trusting an undocumented observer-pointer or userInfo layout.
        for entry in entries.values { entry.continuation.yield(()) }
    }
    private func remove(_ token: UUID) {
        guard let entry = entries.removeValue(forKey: token),
              !entries.values.contains(where: { $0.displayID == entry.displayID }) else { return }
        _ = unregister?(entry.displayID, entry.displayID)
        registered.remove(entry.displayID)
    }
}
