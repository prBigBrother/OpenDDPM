import Foundation
final class QueueTransport: MonitorTransport {
    var registers = [0x10: 50, 0x12: 75, 0x66: 1, 0x62: 30, 0xE2: 0]
    var brightnessWrites = 0
    var reads = 0
    var discoveries = 0
    var failBrightnessReads = false
    var ignoreBrightnessWrites = false
    var brightnessOperations = [String]()
    func run(_ args: [String], timeout: TimeInterval) throws -> String {
        if args[0] == "list" { discoveries += 1; return "[{\"serial\":\"TEST\",\"displayID\":42}]" }
        Thread.sleep(forTimeInterval: 0.04)
        let reg = Int(args[2].dropFirst(2), radix: 16)!
        if args[0] == "write" {
            if reg == 0x10 {
                brightnessWrites += 1; brightnessOperations.append("write:\(args[3])")
                if !ignoreBrightnessWrites { registers[reg] = Int(args[3])! }
            } else { registers[reg] = Int(args[3])! }
            return ""
        }
        reads += 1
        if reg == 0x10 { brightnessOperations.append("read") }
        if reg == 0x10 && failBrightnessReads { throw ControlError.message("Transient DDC failure") }
        return String(registers[reg] ?? 0xffff)
    }
}
final class ObservableNativeBrightness: NativeBrightnessControlling {
    var value = 80
    var writes = 0
    var failReads = false
    var preciseValue: Double?
    var nativeReads = 0
    func supports(_ displayID: UInt32) -> Bool { displayID == 42 }
    func read(_ displayID: UInt32) throws -> Int {
        if failReads { throw ControlError.message("Transient read failure") }
        return value
    }
    func readPrecise(_ displayID: UInt32) throws -> Double {
        nativeReads += 1
        return try preciseValue ?? Double(read(displayID))
    }
    func write(_ value: Int, displayID: UInt32) throws { writes += 1; self.value = value; preciseValue = nil }
}
@MainActor
final class TestBrightnessChanges: BrightnessChangeNotifying {
    var available = true
    var continuation: AsyncStream<Void>.Continuation?
    func events(displayID: UInt32) -> AsyncStream<Void>? {
        guard available else { return nil }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.yield(())
        }
    }
    func signal() { continuation?.yield(()) }
}
@main struct MonitorPictureControllerTests {
    @MainActor static func main() async throws {
        let transport = QueueTransport()
        let journal = TransitionJournal(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("queue-test-\(UUID()).jsonl"))
        defer { try? FileManager.default.removeItem(at: journal.url) }
        let engine = MonitorEngine(transport: transport, timing: EngineTiming(), journal: journal)
        let controls = MonitorControls()
        controls.connect(serial: "TEST", engine: engine)
        controls.allowsControl = { true }
        controls.updateHDR(false)
        await controls.refresh()
        let initialReads = transport.reads
        await controls.refresh(ifStale: true)
        precondition(transport.reads == initialReads, "Background poll must not restart picture reads immediately")
        let refresh = Task { await controls.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(controls.working)
        controls.stepBrightness(6.25)
        await refresh.value
        for _ in 0..<20 where controls.working { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(controls.values[0x10] == 56 && transport.brightnessWrites == 1, "Key pressed during refresh must drain")
        controls.stepBrightness(6.25)
        controls.stepBrightness(6.25)
        controls.stepBrightness(6.25)
        for _ in 0..<30 where controls.working { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(controls.values[0x10] == 74, "Hardware repeats must accumulate and coalesce")
        let beforeHDR = transport.brightnessWrites
        controls.updateHDR(true)
        controls.stepBrightness(-6.25)
        for _ in 0..<20 where controls.working { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(transport.brightnessWrites == beforeHDR + 1, "HDR alone must not block working keyboard brightness")
        controls.set(.brightness, to: 20)
        for _ in 0..<20 where controls.working { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(controls.values[0x10] == 20 && controls.canAdjustBrightness, "Slider and keys must share the same brightness path in HDR")
        controls.updateHDR(nil)
        precondition(controls.canAdjustBrightness, "Unknown HDR must not prevent native brightness")
        controls.updateHDR(false)
        let before = transport.brightnessWrites
        controls.setAutoBrightness(true)
        controls.stepBrightness(6.25)
        for _ in 0..<20 where controls.working { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(controls.autoBrightness && transport.brightnessWrites == before, "Queued manual adjustment must be discarded after enabling auto brightness")
        transport.failBrightnessReads = true
        await controls.refresh()
        precondition(controls.values[0x10] == 20 && controls.failures[0x10] != nil,
                     "A failed DDC refresh must preserve confirmed brightness and expose its error")
        transport.failBrightnessReads = false
        let native = ObservableNativeBrightness()
        transport.registers[0x66] = 1
        let nativeEngine = MonitorEngine(transport: transport, timing: EngineTiming(), journal: journal, nativeBrightness: native)
        let changes = TestBrightnessChanges()
        let observed = MonitorControls(brightnessChanges: changes, brightnessVerificationTimeout: 0.5)
        observed.connect(serial: "TEST", engine: nativeEngine, displayID: 42)
        observed.allowsControl = { true }
        await observed.refresh()
        precondition(observed.values[0x10] == 80)
        let readsBeforeSample = transport.reads, discoveriesBeforeSample = transport.discoveries
        let writesBeforeSample = transport.brightnessWrites
        native.value = 43 // A keyboard/system change bypassing OpenDDPM's setter.
        await observed.synchronizeNativeBrightness()
        precondition(observed.values[0x10] == 43, "External native brightness must update the shared slider value")
        precondition(transport.reads == readsBeforeSample && transport.discoveries == discoveriesBeforeSample,
                     "Live observation must not poll DDC or rediscover hardware")
        precondition(native.writes == 0 && transport.brightnessWrites == writesBeforeSample,
                     "Synchronizing the thumb must not send any brightness write")
        let observation = Task { await observed.observeNativeBrightness() }
        try await Task.sleep(nanoseconds: 20_000_000)
        native.value = 41
        changes.signal()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(observed.values[0x10] == 41, "A native notification must update visible controls immediately")
        native.preciseValue = 41.375
        changes.signal()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(observed.preciseBrightness == 41.375 && observed.values[0x10] == 41,
                     "The slider must preserve fractional brightness while the label stays rounded")
        let readsAfterSignal = native.nativeReads
        native.preciseValue = nil
        native.value = 20
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(native.nativeReads == readsAfterSignal && observed.values[0x10] == 41,
                     "Successful native registration must not retain the 250 ms polling loop")
        observed.suspended = true
        native.value = 20
        await observed.synchronizeNativeBrightness()
        precondition(observed.values[0x10] == 41, "Suspended controls must not publish external samples")
        observation.cancel()
        await observation.value
        observed.suspended = false
        native.failReads = true
        await observed.synchronizeNativeBrightness()
        precondition(observed.values[0x10] == 41, "A transient read error must preserve the last confirmed slider position")
        observed.set(.brightness, to: 35)
        for _ in 0..<20 where observed.working { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(observed.values[0x10] == 41 && observed.failures[0x10] != nil && observed.message != nil,
                     "An unverified write must expose its error, retain the last confirmed value, and allow retry")
        native.failReads = false
        native.value = 17
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(observed.values[0x10] == 41, "Closing controls must cancel observation")
        let fallbackChanges = TestBrightnessChanges()
        fallbackChanges.available = false
        let fallback = MonitorControls(brightnessChanges: fallbackChanges)
        fallback.connect(serial: "TEST", engine: nativeEngine, displayID: 42)
        fallback.allowsControl = { true }
        await fallback.refresh()
        let fallbackObservation = Task { await fallback.observeNativeBrightness() }
        native.value = 19
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(fallback.values[0x10] == 19, "Unavailable notification registration must retain a working fallback")
        fallbackObservation.cancel()
        await fallbackObservation.value
        let fastTransport = QueueTransport()
        let fastEngine = MonitorEngine(transport: fastTransport, timing: EngineTiming(), journal: journal)
        let fast = MonitorControls(brightnessVerificationTimeout: 0.7)
        fast.connect(serial: "TEST", engine: fastEngine)
        fast.allowsControl = { true }
        await fast.refresh()
        fastTransport.brightnessOperations = []
        var previews = [Int]()
        var verified = [Int]()
        fast.onBrightnessRequested = { previews.append($0) }
        fast.onBrightnessVerified = { verified.append($0) }
        fast.stepBrightness(-6.25)
        precondition(fast.brightnessPreview == 44 && fast.values[0x10] == 50 && previews == [44],
                     "Key feedback must be immediate without claiming the requested value as confirmed")
        for _ in 0..<20 where fastTransport.brightnessWrites == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        fast.stepBrightness(-6.25); fast.stepBrightness(-6.25); fast.stepBrightness(-6.25)
        for _ in 0..<60 where fast.working { try await Task.sleep(nanoseconds: 30_000_000) }
        precondition(fastTransport.brightnessOperations.prefix(2).elementsEqual(["write:44", "write:26"]),
                     "A new burst target must be written before readback of the intermediate target")
        precondition(fast.values[0x10] == 26 && fast.brightnessPreview == nil && verified == [26])
        fastTransport.failBrightnessReads = true
        fast.stepBrightness(-6.25)
        let readsBeforeRetry = fastTransport.reads
        for _ in 0..<40 where fastTransport.reads == readsBeforeRetry { try await Task.sleep(nanoseconds: 10_000_000) }
        fast.stepBrightness(-6.25)
        for _ in 0..<30 where fastTransport.registers[0x10] != 14 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(fastTransport.registers[0x10] == 14 && fast.working,
                     "A new key must preempt failed readback rather than wait for the verification timeout")
        fastTransport.failBrightnessReads = false
        for _ in 0..<60 where fast.working { try await Task.sleep(nanoseconds: 30_000_000) }
        precondition(fast.values[0x10] == 14 && verified.last == 14)
        fastTransport.ignoreBrightnessWrites = true
        fast.stepBrightness(-6.25)
        for _ in 0..<60 where fast.working { try await Task.sleep(nanoseconds: 30_000_000) }
        precondition(fast.values[0x10] == 14 && fast.brightnessPreview == nil && fast.failures[0x10] != nil && verified.last == 14,
                     "An ignored write must revert the preview and expose failure, never publish a false confirmation")
        print("PASS: HDR preserves keyboard and slider brightness; repeats coalesce; refresh is throttled; automatic brightness blocks queued adjustments; native notifications preserve fractions without fast polling; fallback and cancellation work")
    }
}
