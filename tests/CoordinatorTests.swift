import Foundation

final class ModelTransport: MonitorTransport {
    var state = MonitorStatus(mode: 0x24, main: .dp, secondary: .thunderbolt, localInput: .dp)
    var writes: [Int] = []
    var invalidReads = 0
    var offline = false
    var ambiguousWrite = false
    var readsAfterHidden = 0
    var hidden = false
    func run(_ args: [String], timeout: TimeInterval) throws -> String {
        if offline { throw ControlError.message("offline") }
        if args[0] == "list" { return "[]" }
        let register = Int(args[2].dropFirst(2), radix: 16)!
        if args[0] == "read" {
            if hidden { readsAfterHidden += 1; throw ControlError.message("hidden") }
            if invalidReads > 0 { invalidReads -= 1; return "65535" }
            switch register { case 0xe9: return String(state.mode); case 0x60: return String(0x0f00 | state.main.code); default: return String(state.secondary?.code ?? 0xffff) }
        }
        writes.append(register)
        let value = Int(args[3].dropFirst(2), radix: 16)!
        switch register {
        case 0xe9: state.mode = value
        case 0x60:
            let input = VideoInput(code: value)!
            if state.secondary == input { state.secondary = state.main }
            state.main = input
        default: state.secondary = VideoInput(code: value)
        }
        hidden = state.main != .dp && (state.mode == 0 || state.secondary != .dp)
        if ambiguousWrite { ambiguousWrite = false; throw ControlError.message("reply lost after accepted write") }
        return ""
    }
}

actor GatedEngine: MonitorControlling {
    var started: [UUID] = []
    var active = 0
    var maxActive = 0
    var gate: CheckedContinuation<Void, Never>?
    var fail = false
    var current = MonitorStatus(mode: 0, main: .dp, secondary: nil, localInput: .dp)
    func discover() -> [ConnectedMonitor] { [] }
    func status(serial: String) -> MonitorStatus { current }
    func apply(_ preset: DisplayPreset, configuration: AppConfiguration, request: UUID,
               isCurrent: @escaping @Sendable () async -> Bool,
               progress: @escaping @Sendable (String) async -> Void) async throws -> ApplyResult {
        active += 1; maxActive = max(active, maxActive); started.append(preset.id)
        await withCheckedContinuation { gate = $0 }
        active -= 1
        if fail { fail = false; throw ControlError.message("stale failure") }
        guard await isCurrent() else { return .superseded }
        current = MonitorStatus(mode: preset.layout.code, main: preset.main, secondary: preset.layout == .full ? nil : preset.secondary, localInput: .dp)
        return .verified(current)
    }
    func release(failure: Bool = false) { fail = failure; let continuation = gate; gate = nil; continuation?.resume() }
}

actor CurrentSwitch {
    var checks = 0
    func current() -> Bool { checks += 1; return checks < 4 }
}

@main
@MainActor
struct CoordinatorTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) {
        count += 1
        if !condition() { fputs("FAIL: \(text)\n", stderr); exit(1) }
    }
    static func waitForStart(_ engine: GatedEngine, _ count: Int) async {
        for _ in 0..<200 { if await engine.started.count >= count { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        check(false, "worker starts")
    }
    static func drain(_ coordinator: PresetCoordinator) async {
        for _ in 0..<200 { if !coordinator.busy { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        check(false, "worker drains")
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDDPM-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TransitionJournal(url: directory.appendingPathComponent("trace.jsonl"))
        var configuration = AppConfiguration(); configuration.monitorSerial = "TEST"; configuration.inputConfirmed = true
        let a = DisplayPreset(name: "A", layout: .full, main: .dp, secondary: .thunderbolt)
        let b = DisplayPreset(name: "B", layout: .equal, main: .dp, secondary: .thunderbolt)
        let c = DisplayPreset(name: "C", layout: .largeLeft, main: .dp, secondary: .thunderbolt)
        configuration.presets = [a, b, c]
        let gated = GatedEngine(), coordinator = PresetCoordinator(engine: gated, journal: journal)
        let first = try coordinator.submit(a, configuration: configuration)
        await waitForStart(gated, 1)
        let second = try coordinator.submit(b, configuration: configuration)
        let final = try coordinator.submit(c, configuration: configuration)
        let duplicate = try coordinator.submit(c, configuration: configuration)
        check(duplicate == final, "duplicate current request is coalesced")
        await gated.release(failure: true)
        await waitForStart(gated, 2)
        check(coordinator.state.error == nil, "stale failure cannot overwrite newer selection")
        await gated.release(); await drain(coordinator)
        let started = await gated.started, maxActive = await gated.maxActive
        check(started == [a.id, c.id], "pending intermediate selection is skipped")
        check(maxActive == 1, "only one transition executes")
        check(coordinator.state.verifiedPresetID == c.id && coordinator.state.requestID == final, "last request is the confirmed result")
        check(coordinator.receipts.first(where: { $0.id == first })?.phase == "superseded", "active superseded request remains terminal")
        check(coordinator.receipts.first(where: { $0.id == second })?.phase == "superseded", "queued superseded request remains terminal")
        _ = try coordinator.submit(a, configuration: configuration); await waitForStart(gated, 3); await gated.release(); await drain(coordinator)
        check(coordinator.state.previousPresetID == c.id, "previous preset is the actual prior confirmed selection")
        coordinator.refresh(configuration: configuration); await drain(coordinator)
        check(coordinator.state.previousPresetID == c.id, "refresh does not corrupt previous preset")
        let interrupted = try coordinator.submit(b, configuration: configuration)
        await waitForStart(gated, 4)
        coordinator.setAvailability("Mac locked")
        await gated.release(); await drain(coordinator)
        check(coordinator.state.phase == "unavailable", "sleep interruption cannot be overwritten by an old result")
        check(coordinator.receipts.first(where: { $0.id == interrupted })?.phase == "failed", "interrupted request has an explicit terminal result")
        do { _ = try coordinator.submit(c, configuration: configuration); check(false, "locked request rejected") } catch { check(true, "locked request rejected") }
        coordinator.setAvailability(nil); coordinator.refresh(configuration: configuration); await drain(coordinator)
        check(coordinator.state.phase == "verified", "wake refresh restores a confirmed state without an automatic preset write")
        coordinator.refresh(configuration: configuration, quietly: true)
        check(!coordinator.busy, "background HomeKit readback does not flash the preset remote busy state")
        for _ in 0..<5 { await Task.yield() }
        var blocked = configuration
        let hiddenPreset = DisplayPreset(name: "Hidden", layout: .full, main: .hdmi, secondary: .thunderbolt)
        do { _ = try coordinator.submit(hiddenPreset, configuration: blocked); check(false, "visibility guard") } catch { check(true, "visibility guard") }

        let transport = ModelTransport()
        let timing = EngineTiming(transition: 0.6, discovery: 0.08, command: 0.02, poll: 0.002, initialSettle: 0.001)
        let engine = MonitorEngine(transport: transport, timing: timing, journal: journal)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await engine.apply(c, configuration: configuration, request: UUID(), isCurrent: { true }, progress: { _ in })
        if case .verified(let status) = result { check(status.matches(c), "adaptive readback verifies whole preset") } else { check(false, "verified result") }
        check(transport.writes == [0xe9], "layout transition retains one-write optimization")
        check(ProcessInfo.processInfo.systemUptime - start < 0.5, "no fixed four-second delay remains")
        _ = try await engine.apply(c, configuration: configuration, request: UUID(), isCurrent: { true }, progress: { _ in })
        check(transport.writes.count == 1, "matching preset performs no writes")
        transport.invalidReads = 2
        _ = try await engine.status(serial: "TEST")
        check(transport.invalidReads == 0, "transient invalid replies are retried")
        transport.ambiguousWrite = true
        _ = try await engine.apply(b, configuration: configuration, request: UUID(), isCurrent: { true }, progress: { _ in })
        check(transport.writes.count == 2, "ambiguous accepted write is read back before another write")
        let writes = transport.writes.count
        let superseded = try await engine.apply(c, configuration: configuration, request: UUID(), isCurrent: { false }, progress: { _ in })
        if case .superseded = superseded { check(transport.writes.count == writes, "supersession before write is safe") } else { check(false, "superseded result") }
        let selection = CurrentSwitch()
        let midTransition = try await engine.apply(c, configuration: configuration, request: UUID(), isCurrent: { await selection.current() }, progress: { _ in })
        if case .superseded = midTransition { check(transport.writes.count == writes + 1, "new target is honored after the current hardware transaction") } else { check(false, "mid-transition supersession") }
        let recovered = try await engine.apply(b, configuration: configuration, request: UUID(), isCurrent: { true }, progress: { _ in })
        if case .verified(let state) = recovered { check(state.matches(b), "next target replans from actual partial state") } else { check(false, "partial-state recovery") }
        blocked.keepLocalVisible = false
        let unverified = try await engine.apply(hiddenPreset, configuration: blocked, request: UUID(), isCurrent: { true }, progress: { _ in })
        if case .unverified = unverified { check(transport.readsAfterHidden == 0, "visibility-removing final write is not reported as verified") } else { check(false, "unverified result") }
        transport.offline = true
        let outage = ProcessInfo.processInfo.systemUptime
        do { _ = try await engine.status(serial: "TEST"); check(false, "offline fails") } catch { check(ProcessInfo.processInfo.systemUptime - outage < 0.3, "offline retries share a bounded deadline") }
        let rows = try String(contentsOf: journal.url, encoding: .utf8).split(separator: "\n")
        check(rows.count > 10, "journal contains request and I/O events")
        for row in rows { _ = try JSONSerialization.jsonObject(with: Data(row.utf8)) }
        let body = "{\"preset\":\"test\"}"
        let packet = Data("POST /apply HTTP/1.1\r\nAuthorization: Bearer local\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        let parsed = try HTTPRequest.parse(packet)
        check(parsed?.body == Data(body.utf8), "automation parses complete requests")
        let partial = try HTTPRequest.parse(packet.dropLast())
        check(partial == nil, "fragmented bodies wait for completion")
        for invalid in ["GET / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n"] {
            do { _ = try HTTPRequest.parse(Data(invalid.utf8)); check(false, "malformed HTTP rejected") } catch { check(true, "malformed HTTP rejected") }
        }
        print("PASS: \(count) coordinator, readiness, recovery and deadline assertions")
    }
}
