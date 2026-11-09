import Foundation
import Combine

@MainActor
final class MonitorControls: ObservableObject {
    @Published private(set) var preciseBrightness: Double?
    @Published private(set) var brightnessPreview: Int?
    @Published private(set) var requestedValues: [Int: Int] = [:]
    @Published private(set) var hdrPreview: Bool?
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
    var autoBrightness: Bool { displayedValue(for: .automatic).map { ($0 & 3) == 2 } ?? false }
    func displayedValue(for feature: PictureFeature) -> Int? { requestedValues[feature.register] ?? values[feature.register] }
    var onBrightnessVerified: ((Int) -> Void)?
    private var synchronizeAfterOperation = false
    private enum Request {
        case picture(PictureFeature, value: Int, mask: Int)
        case hdr(Bool, @MainActor () async -> Void)
        var key: String {
            switch self {
            case let .picture(feature, _, mask): return "\(feature.register):\(mask)"
            case .hdr: return "hdr"
            }
        }
        var brightness: Int? {
            if case let .picture(feature, value, _) = self, feature.register == 0x10 { return value }
            return nil
        }
        var isPicture: Bool { if case .picture = self { return true }; return false }
    }
    private var requests: [Request] = []
    private var activeRequest: Request?
    private var refreshRequested = false
    private var pendingBrightness: Int? {
        get { requests.first?.brightness }
        set {
            if requests.first?.brightness != nil { requests.removeFirst() }
            if let newValue { requests.insert(.picture(.brightness, value: newValue, mask: 0xffff), at: 0) }
            updatePreviews()
        }
    }
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
    var acceptsChanges: (() -> Bool)?
    var canAcceptChanges: Bool { acceptsChanges?() ?? (!suspended && allowsControl?() == true) }
    var allowsControl: (() -> Bool)? { didSet { resumePendingChanges() } }
    var suspended = false { didSet { if !suspended { resumePendingChanges() } } }

    private func updatePreviews() {
        var desired: [Int: Int] = [:]
        var desiredHDR: Bool?
        for request in (activeRequest.map { [$0] } ?? []) + requests {
            switch request {
            case let .picture(feature, value, mask):
                let before = desired[feature.register] ?? values[feature.register] ?? value
                desired[feature.register] = (before & ~mask) | (value & mask)
            case let .hdr(value, _): desiredHDR = value
            }
        }
        requestedValues = desired
        brightnessPreview = desired[0x10]
        hdrPreview = desiredHDR
    }
    private func enqueue(_ request: Request) {
        if let index = requests.firstIndex(where: { $0.key == request.key }) { requests[index] = request }
        else { requests.append(request) }
        updatePreviews()
        resumePendingChanges()
    }
    func resumePendingChanges() {
        guard canAcceptChanges else {
            requests.removeAll(); refreshRequested = false; updatePreviews(); return
        }
        guard !working, !suspended, allowsControl?() == true, let engine, !serial.isEmpty else { return }
        guard !requests.isEmpty else {
            if refreshRequested {
                refreshRequested = false
                Task { [weak self] in await self?.refresh() }
            }
            return
        }
        let request = requests.removeFirst()
        if request.brightness != nil, !canAdjustBrightness || values[0x66].map({ ($0 & 3) == 2 }) == true {
            updatePreviews(); resumePendingChanges(); return
        }
        activeRequest = request
        updatePreviews()
        if let value = request.brightness { startKeyboardBrightness(value); return }
        working = true
        let token = generation, target = serial, targetDisplay = displayID
        Task {
            defer { completeOperation(token: token) }
            guard token == generation else { return }
            guard allowsControl?() == true, !suspended else {
                if !requests.contains(where: { $0.key == request.key }) { requests.insert(request, at: 0) }
                return
            }
            switch request {
            case let .picture(feature, value, mask):
                do {
                    let actual = try await engine.writePicture(feature.register, value: value, serial: target, mask: mask, displayID: targetDisplay)
                    guard token == generation else { return }
                    values[feature.register] = actual; failures[feature.register] = nil
                    if messageRegister == feature.register { message = nil; messageRegister = nil }
                } catch {
                    guard token == generation else { return }
                    failures[feature.register] = error.localizedDescription
                    messageRegister = feature.register
                    message = "\(feature.title): \(error.localizedDescription)"
                }
            case let .hdr(_, operation): await operation()
            }
        }
    }
    func enqueueHDR(_ enabled: Bool, operation: @escaping @MainActor () async -> Void) {
        guard canAcceptChanges, engine != nil, !serial.isEmpty else { return }
        enqueue(.hdr(enabled, operation))
    }
    private func completeOperation(token: UUID) {
        guard token == generation else { resumePendingChanges(); return }
        working = false
        inFlightBrightness = nil
        activeRequest = nil
        updatePreviews()
        resumePendingChanges()
        if synchronizeAfterOperation && !working {
            synchronizeAfterOperation = false
            Task { [weak self] in await self?.synchronizeNativeBrightness() }
        }
    }

    func connect(serial: String, engine: MonitorEngine, displayID: UInt32? = nil) {
        let displayChanged = self.displayID != displayID
        self.displayID = displayID
        guard self.serial != serial || self.engine == nil || displayChanged else { return }
        let sameMonitor = self.serial == serial && self.engine != nil
        if sameMonitor, let activeRequest, activeRequest.isPicture,
           !requests.contains(where: { $0.key == activeRequest.key }) {
            requests.insert(activeRequest, at: 0)
        }
        self.serial = serial; self.engine = engine
        generation = UUID(); activeRequest = nil; working = false; inFlightBrightness = nil
        if !sameMonitor {
            preciseBrightness = nil; values = [:]; failures = [:]; message = nil
            requests.removeAll(); refreshRequested = false; hdrEnabled = nil
        }
        updatePreviews()
        lastRefreshStarted = -.infinity
    }
    func refresh(ifStale: Bool = false) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard !ifStale || now - lastRefreshStarted >= 30 else { return }
        guard !serial.isEmpty, let engine else { return }
        guard !working, !suspended, requests.isEmpty, allowsControl?() == true else {
            if !ifStale { refreshRequested = true }
            return
        }
        refreshHDR?()
        working = true
        lastRefreshStarted = now
        let token = generation, target = serial, targetDisplay = displayID
        defer { completeOperation(token: token) }
        for feature in PictureFeature.all {
            if !requests.isEmpty { break }
            guard token == generation, allowsControl?() == true else { return }
            do {
                let value = try await engine.readPicture(feature.register, serial: target, displayID: targetDisplay)
                guard token == generation else { return }
                guard feature.accepts(value) else { throw ControlError.message("Unsupported value: \(value)") }
                values[feature.register] = value; failures[feature.register] = nil
                if feature.register == 0x10 { preciseBrightness = Double(value) }
            } catch {
                guard token == generation else { return }
                // Keep confirmed values editable after transient read failures.
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
        guard canAdjustBrightness, canAcceptChanges, let current = requestedValues[0x10] ?? inFlightBrightness ?? values[0x10] else { return }
        let next = min(100, max(0, Int((Double(current) + increment).rounded())))
        onBrightnessRequested?(next)
        set(.brightness, to: next)
    }
    private func startKeyboardBrightness(_ initial: Int) {
        guard !working, canAdjustBrightness, allowsControl?() == true, let engine else { return }
        working = true
        let token = generation, targetSerial = serial, targetDisplay = displayID
        inFlightBrightness = initial
        brightnessRevision &+= 1
        Task {
            defer { completeOperation(token: token) }
            var target = initial
            do {
                while token == generation, canAdjustBrightness {
                    guard allowsControl?() == true, !suspended else {
                        if !requests.contains(where: { $0.brightness != nil }) {
                            requests.insert(.picture(.brightness, value: target, mask: 0xffff), at: 0)
                        }
                        return
                    }
                    if let latest = pendingBrightness { target = latest }
                    inFlightBrightness = target
                    activeRequest = .picture(.brightness, value: target, mask: 0xffff)
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
                        guard token == generation, canAdjustBrightness else { return }
                        if allowsControl?() != true || suspended {
                            if !requests.contains(where: { $0.brightness != nil }) {
                                requests.insert(.picture(.brightness, value: target, mask: 0xffff), at: 0)
                            }
                            return
                        }
                        do {
                            let actual = try await engine.readPicture(0x10, serial: targetSerial, displayID: targetDisplay)
                            guard token == generation else { return }
                            if pendingBrightness != nil { break }
                            confirmations = actual == target ? confirmations + 1 : 0
                            last = "Monitor returned \(actual) after requesting \(target)."
                            if confirmations >= 2 {
                                values[0x10] = actual; preciseBrightness = Double(actual); failures[0x10] = nil
                                if messageRegister == 0x10 { message = nil; messageRegister = nil }
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
                failures[0x10] = error.localizedDescription
                messageRegister = 0x10
                message = "Brightness: \(error.localizedDescription)"
            }
        }
    }
    func setAutoBrightness(_ enabled: Bool) {
        guard let raw = displayedValue(for: .automatic) else { return }
        set(.automatic, to: (raw & ~3) | (enabled ? 2 : 1), mask: 3)
    }
    func setAutoRange(_ level: Int) {
        guard let raw = displayedValue(for: .automatic), (0...2).contains(level) else { return }
        set(.automatic, to: (raw & ~0xc0) | (level << 6), mask: 0xc0)
    }
    func set(_ feature: PictureFeature, to value: Int, mask: Int = 0xffff) {
        guard !(feature.register == 0x10 && !canAdjustBrightness), canAcceptChanges,
              feature.accepts(value), engine != nil, !serial.isEmpty else { return }
        guard mask == 0xffff || (feature.register == 0x66 && (mask == 3 || mask == 0xc0)) else { return }
        enqueue(.picture(feature, value: value, mask: mask))
    }
}
