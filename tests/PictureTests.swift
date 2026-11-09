import Foundation

final class PictureTransport: MonitorTransport {
    var registers = [0x66: 0x1281, 0x10: 75]
    var writes = [(Int, Int)]()
    var ignoreWrites = false
    var failingReads = 0
    func run(_ arguments: [String], timeout: TimeInterval) throws -> String {
        if arguments[0] == "list" { return "[{\"serial\":\"TEST\",\"displayID\":42}]" }
        let register = Int(arguments[2].dropFirst(2), radix: 16)!
        if arguments[0] == "write" {
            let value = Int(arguments[3])!
            writes.append((register, value))
            if !ignoreWrites { registers[register] = value }
            return ""
        }
        if failingReads > 0 { failingReads -= 1; throw ControlError.message("Transient DDC failure") }
        guard let value = registers[register] else { throw ControlError.message("Unsupported") }
        return String(value)
    }
}


final class TestNativeBrightness: NativeBrightnessControlling {
    var value = 80
    var writes = 0
    func supports(_ displayID: UInt32) -> Bool { displayID == 42 }
    func read(_ displayID: UInt32) throws -> Int { value }
    func write(_ value: Int, displayID: UInt32) throws { self.value = value; writes += 1 }
}

@main
struct PictureTests {
    static func main() async throws {
        let transport = PictureTransport()
        let journal = TransitionJournal(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picture-test-\(UUID()).jsonl"))
        defer { try? FileManager.default.removeItem(at: journal.url) }
        let engine = MonitorEngine(transport: transport, timing: EngineTiming(discovery: 1.8), journal: journal)
        let enabled = try await engine.writePicture(0x66, value: 2, serial: "TEST", mask: 3)
        precondition(enabled == 0x1282, "Auto toggle preserves range and unrelated flags")
        let range = try await engine.writePicture(0x66, value: 0x40, serial: "TEST", mask: 0xc0)
        precondition(range == 0x1242, "Range change preserves automatic mode and unrelated flags")
        do {
            _ = try await engine.writePicture(0x66, value: 0, serial: "TEST")
            fatalError("Unmasked packed register write accepted")
        } catch {}
        do {
            _ = try await engine.writePicture(0x10, value: 101, serial: "TEST")
            fatalError("Out of range brightness accepted")
        } catch {}
        do {
            _ = try await engine.writePicture(0xff, value: 1, serial: "TEST")
            fatalError("Unknown register accepted")
        } catch {}
        precondition(transport.writes.count == 2, "Rejected requests must not write")
        let movie = try await engine.writePicture(0xE2, value: 2, serial: "TEST")
        precondition(movie == 2 && transport.writes.last?.0 == 0xdc && transport.writes.last?.1 == 3,
                     "Movie capability ID must map to DC03, with command register readback")
        precondition(PictureFeature.colorCommand(0x0f)?.register == 0x14 && PictureFeature.colorCommand(0x0f)?.value == 5)
        precondition(PictureFeature.colorCommand(0x1b)?.register == 0xf0 && PictureFeature.colorCommand(0x1b)?.value == 10)
        transport.failingReads = 3
        let writesBeforeRetry = transport.writes.count
        let retried = try await engine.writePicture(0x10, value: 60, serial: "TEST")
        precondition(retried == 60 && transport.writes.count == writesBeforeRetry + 1,
                     "Transient read failures must recover without repeating the write")
        transport.ignoreWrites = true
        do {
            _ = try await engine.writePicture(0x10, value: 50, serial: "TEST")
            fatalError("Acknowledgement without readback was accepted")
        } catch {}
        precondition(!PictureFeature.automatic.accepts(0xffff))
        precondition(!PictureFeature.automatic.accepts(0xc2))
        let discovered = try ConnectedMonitor.decode("[{\"serial\":\"TEST\",\"displayID\":42}]")
        precondition(discovered.first?.displayID == 42)
        let native = TestNativeBrightness()
        let nativeEngine = MonitorEngine(transport: transport, timing: EngineTiming(), journal: journal, nativeBrightness: native)
        let nativeRead = try await nativeEngine.readPicture(0x10, serial: "TEST", displayID: 42)
        precondition(nativeRead == 80, "Native current brightness must take precedence over a fixed DDC value")
        let ddcWrites = transport.writes.count
        let nativeSet = try await nativeEngine.writePicture(0x10, value: 56, serial: "TEST", displayID: 42)
        precondition(nativeSet == 56 && native.writes == 1 && transport.writes.count == ddcWrites,
                     "Native brightness must bypass DDC and verify the same native backend")
        do {
            _ = try await nativeEngine.writePicture(0x10, value: 30, serial: "OTHER", displayID: 42)
            fatalError("Native brightness targeted a different serial")
        } catch {}
        precondition(native.writes == 1, "Stale display identity must be rejected before writing")
        transport.ignoreWrites = false
        transport.failingReads = 3
        let writesBeforeSend = transport.writes.count
        try await engine.sendBrightness(45, serial: "TEST", displayID: nil)
        precondition(transport.writes.count == writesBeforeSend + 1 && transport.failingReads == 3,
                     "Fast brightness sends must not block on verification reads")
        print("PASS: picture writes preserve packed fields, reject invalid commands, verify actual readback, carry display identity, and route native brightness without DDC")
    }
}
