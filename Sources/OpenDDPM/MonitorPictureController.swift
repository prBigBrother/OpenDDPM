import Foundation
import Combine

@MainActor
final class MonitorControls: ObservableObject {
    @Published private(set) var preciseBrightness: Double?
    @Published private(set) var brightnessPreview: Int?
    var displayedBrightness: Double? { brightnessPreview.map(Double.init) ?? preciseBrightness ?? values[0x10].map(Double.init) }
    var onBrightnessRequested: ((Int) -> Void)?
    @Published private(set) var values: [Int: Int] = [:]
    @Published private(set) var failures: [Int: String] = [:]
    @Published private(set) var working = false
    @Published var message: String?
    @Published private(set) var hdrEnabled: Bool?
    var brightnessLockReason: String? { autoBrightness ? "Automatic brightness is on." : nil }
    var canAdjustBrightness: Bool { brightnessLockReason == nil }
    func updateHDR(_ enabled: Bool?) { hdrEnabled = enabled }
    private var messageRegister: Int?
    var refreshHDR: (() -> Void)?
    var autoBrightness: Bool { values[0x66].map { ($0 & 3) == 2 } ?? false }
    var onBrightnessVerified: ((Int) -> Void)?
    private var synchronizeAfterOperation = false
    private var pendingBrightness: Int?
    private var inFlightBrightness: Int?
    private var lastRefreshStarted: TimeInterval = -.infinity
    var nativeObservationIdentity: String { "\(serial):\(displayID ?? 0)" }
    private var displayID: UInt32?
    private var serial = ""
    private let brightnessChanges: BrightnessChangeNotifying
    private let brightnessVerificationTimeout: TimeInterval
    init(brightnessChanges: BrightnessChangeNotifying? = nil, brightnessVerificationTimeout: TimeInterval = 8) {
        self.brightnessVerificationTimeout = brightnessVerificationTimeout
        self.brightnessChanges = brightnessChanges ?? NativeBrightnessNotifications.shared
    }
    private var generation = UUID()
    private var brightnessRevision: UInt64 = 0
    private var engine: MonitorEngine?
    var allowsControl: (() -> Bool)?
    var suspended = false

    private func completeOperation() {
        working = false
        inFlightBrightness = nil
        if let pending = pendingBrightness {
            pendingBrightness = nil
            if canAdjustBrightness, values[0x10] != nil { startKeyboardBrightness(pending) }
        }
        if !working { brightnessPreview = nil }
        if synchronizeAfterOperation && !working {
            synchronizeAfterOperation = false
            Task { [weak self] in await self?.synchronizeNativeBrightness() }
        }
    }

    func connect(serial: String, engine: MonitorEngine, displayID: UInt32? = nil) {
        let displayChanged = self.displayID != displayID
        self.displayID = displayID
        guard self.serial != serial || self.engine == nil || displayChanged else { return }
        self.serial = serial; self.engine = engine
        generation = UUID(); preciseBrightness = nil; brightnessPreview = nil; values = [:]; failures = [:]; message = nil; pendingBrightness = nil; hdrEnabled = nil
        lastRefreshStarted = -.infinity
    }
    func refresh(ifStale: Bool = false) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard !ifStale || now - lastRefreshStarted >= 30 else { return }
        guard !working, !serial.isEmpty, let engine, allowsControl?() == true else { return }
        refreshHDR?()
        working = true
        lastRefreshStarted = now
        let token = generation, target = serial, targetDisplay = displayID
        defer { completeOperation() }
        for feature in PictureFeature.all {
            if pendingBrightness != nil { break }
            guard token == generation, allowsControl?() == true else { return }
            do {
                let value = try await engine.readPicture(feature.register, serial: target, displayID: targetDisplay)
                guard token == generation else { return }
                guard feature.accepts(value) else { throw ControlError.message("Unsupported value: \(value)") }
                values[feature.register] = value; failures[feature.register] = nil
                if feature.register == 0x10 { preciseBrightness = Double(value) }
            } catch {
                guard token == generation else { return }
                // Retain the last confirmed brightness on a transient DDC
                // failure, while exposing the failure and permitting a retry.
                if feature.register != 0x10 { values[feature.register] = nil }
                failures[feature.register] = error.localizedDescription
            }
        }
    }
    /// Runs only for the lifetime of a visible settings page or quick menu.
    /// System/keyboard brightness changes do not necessarily pass through our tap.
    func observeNativeBrightness() async {
        guard let id = displayID else { return }
        let token = generation
        if let events = brightnessChanges.events(displayID: id) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    for await _ in events {
                        guard let self, !Task.isCancelled, self.generation == token else { return }
                        await self.synchronizeNativeBrightness()
                    }
                }
                // Slow recovery for missed private-API notifications. Normal
                // updates are pushed immediately, without a 250 ms timer.
                group.addTask { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                        guard let self, self.generation == token else { return }
                        await self.synchronizeNativeBrightness()
                    }
                }
                _ = await group.next()
                group.cancelAll()
            }
        } else {
            // Compatibility fallback only when native registration is unavailable.
            while !Task.isCancelled, generation == token {
                await synchronizeNativeBrightness()
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }
    func synchronizeNativeBrightness() async {
        if working { synchronizeAfterOperation = true; return }
        guard !suspended, allowsControl?() == true, let engine, let displayID else { return }
        let token = generation, revision = brightnessRevision, target = serial
        do {
            guard let value = try await engine.sampleNativeBrightness(serial: target, displayID: displayID),
                  !Task.isCancelled, !working, !suspended, token == generation, revision == brightnessRevision,
                  self.displayID == displayID, allowsControl?() == true,
                  value.isFinite, (0...100).contains(value) else { return }
            let rounded = Int(value.rounded())
            if values[0x10] != rounded { values[0x10] = rounded }
            if preciseBrightness == nil || abs((preciseBrightness ?? value) - value) > 0.001 { preciseBrightness = value }
            if failures[0x10] != nil { failures[0x10] = nil }
        } catch {
            // A transient sample failure must not erase the last confirmed value
            // or interrupt dragging. Explicit refresh still reports failures.
        }
    }
    func stepBrightness(_ increment: Double) {
        guard canAdjustBrightness, allowsControl?() == true, let current = pendingBrightness ?? inFlightBrightness ?? values[0x10] else { return }
        let next = min(100, max(0, Int((Double(current) + increment).rounded())))
        brightnessPreview = next
        onBrightnessRequested?(next)
        if working { pendingBrightness = next }
        else { startKeyboardBrightness(next) }
    }
    private func startKeyboardBrightness(_ initial: Int) {
        guard !working, canAdjustBrightness, allowsControl?() == true, let engine else { return }
        working = true; message = nil; messageRegister = nil
        let token = generation, targetSerial = serial, targetDisplay = displayID
        inFlightBrightness = initial
        brightnessRevision &+= 1
        Task {
            defer { completeOperation() }
            var target = initial
            do {
                while token == generation, allowsControl?() == true, canAdjustBrightness {
                    if let latest = pendingBrightness { target = latest }
                    inFlightBrightness = target
                    pendingBrightness = nil
                    try await engine.sendBrightness(target, serial: targetSerial, displayID: targetDisplay)
                    guard token == generation else { return }
                    // New key repeats can replace the target during every await.
                    // Do not read back each intermediate write in a held key burst.
                    if pendingBrightness == nil { try await Task.sleep(nanoseconds: 180_000_000) }
                    if let next = pendingBrightness { target = next; continue }
                    let deadline = ProcessInfo.processInfo.systemUptime + brightnessVerificationTimeout
                    var confirmations = 0
                    var last = "No valid reply."
                    while pendingBrightness == nil, ProcessInfo.processInfo.systemUptime < deadline {
                        guard token == generation, allowsControl?() == true, canAdjustBrightness else { return }
                        do {
                            let actual = try await engine.readPicture(0x10, serial: targetSerial, displayID: targetDisplay)
                            guard token == generation else { return }
                            if pendingBrightness != nil { break }
                            confirmations = actual == target ? confirmations + 1 : 0
                            last = "Monitor returned \(actual) after requesting \(target)."
                            if confirmations >= 2 {
                                values[0x10] = actual; preciseBrightness = Double(actual); failures[0x10] = nil
                                onBrightnessVerified?(actual)
                                return
                            }
                        } catch { last = error.localizedDescription }
                        // Yield between reads, so a new key can preempt verification.
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    if let next = pendingBrightness { target = next; continue }
                    throw ControlError.message("Brightness was not confirmed before the time limit. \(last)")
                }
            } catch {
                guard token == generation else { return }
                pendingBrightness = nil
                failures[0x10] = error.localizedDescription
                messageRegister = 0x10
                message = "Brightness: \(error.localizedDescription)"
            }
        }
    }
    func setAutoBrightness(_ enabled: Bool) {
        guard let raw = values[0x66] else { return }
        set(.automatic, to: (raw & ~3) | (enabled ? 2 : 1), mask: 3)
    }
    func setAutoRange(_ level: Int) {
        guard let raw = values[0x66], (0...2).contains(level) else { return }
        set(.automatic, to: (raw & ~0xc0) | (level << 6), mask: 0xc0)
    }
    func set(_ feature: PictureFeature, to value: Int, mask: Int = 0xffff) {
        guard !(feature.register == 0x10 && !canAdjustBrightness), allowsControl?() == true, feature.accepts(value), let engine, !serial.isEmpty else { return }
        if feature.register == 0x10 {
            brightnessPreview = value
            if working { pendingBrightness = value }
            else { startKeyboardBrightness(value) }
            return
        }
        guard !working else { return }
        working = true; message = nil; messageRegister = nil
        let token = generation, target = serial, targetDisplay = displayID
        Task {
            defer { completeOperation() }
            do {
                let actual = try await engine.writePicture(feature.register, value: value, serial: target, mask: mask, displayID: targetDisplay)
                guard token == generation else { return }
                values[feature.register] = actual; failures[feature.register] = nil
            } catch {
                guard token == generation else { return }
                pendingBrightness = nil
                // Retain the last confirmed brightness on a transient DDC
                // failure, while exposing the failure and permitting a retry.
                if feature.register != 0x10 { values[feature.register] = nil }
                failures[feature.register] = error.localizedDescription
                messageRegister = feature.register
                message = "\(feature.title): \(error.localizedDescription)"
            }
        }
    }
}
