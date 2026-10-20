import Foundation
import Darwin

protocol MonitorTransport {
    func run(_ arguments: [String], timeout: TimeInterval) throws -> String
}

struct HelperRunner: MonitorTransport {
    let executable: URL
    func run(_ arguments: [String], timeout: TimeInterval = 3) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() }
        catch { throw ControlError.message("The built-in monitor driver could not start: \(error.localizedDescription)") }
        // SIGKILL bounds a stuck IOKit helper as well as a process that ignores SIGTERM.
        let timer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timer.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !output.hasPrefix("Failed.") else {
            throw ControlError.message(process.terminationReason == .uncaughtSignal ? "Monitor driver timed out." : output.isEmpty ? "The monitor did not respond. Check its cable and DDC/CI setting." : output)
        }
        return output
    }
}

final class TransitionJournal {
    static let standard = TransitionJournal(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpenDDPM/transitions.jsonl"))
    let url: URL
    private let lock = NSLock()
    private(set) var lastError: String?
    init(url: URL) { self.url = url }
    func record(_ event: String, request: UUID? = nil, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var row = fields
        row["event"] = event; row["time"] = ISO8601DateFormatter().string(from: Date())
        if let request { row["requestID"] = request.uuidString }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue > 2_000_000 {
                let previous = url.appendingPathExtension("previous")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
}

struct EngineTiming {
    var transition: TimeInterval = 25
    var discovery: TimeInterval = 8
    var command: TimeInterval = 2
    var poll: TimeInterval = 0.2
    var initialSettle: TimeInterval = 0.15
}

enum ApplyResult {
    case verified(MonitorStatus)
    case unverified
    case superseded
}

protocol MonitorControlling: Actor {
    func discover() async throws -> [ConnectedMonitor]
    func status(serial: String) async throws -> MonitorStatus
    func apply(_ preset: DisplayPreset, configuration: AppConfiguration, request: UUID,
               isCurrent: @escaping @Sendable () async -> Bool,
               progress: @escaping @Sendable (String) async -> Void) async throws -> ApplyResult
}

actor MonitorEngine: MonitorControlling {
    private let transport: MonitorTransport
    private let timing: EngineTiming
    private let journal: TransitionJournal
    private var requestID: UUID?
    init(helper: URL) { transport = HelperRunner(executable: helper); timing = EngineTiming(); journal = .standard }
    init(transport: MonitorTransport, timing: EngineTiming, journal: TransitionJournal) {
        self.transport = transport; self.timing = timing; self.journal = journal
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func command(_ args: [String], deadline: TimeInterval) throws -> String {
        guard now < deadline else { throw ControlError.message("Monitor operation reached its time limit. Retry verification or choose a preset.") }
        let start = now
        do {
            let value = try transport.run(args, timeout: min(timing.command, deadline - now))
            journal.record("io", request: requestID, fields: ["operation": args[0], "arguments": Array(args.dropFirst()), "result": value, "ms": Int((now - start) * 1000)])
            return value
        } catch {
            journal.record("io-error", request: requestID, fields: ["operation": args[0], "arguments": Array(args.dropFirst()), "error": error.localizedDescription, "ms": Int((now - start) * 1000)])
            throw error
        }
    }
    private func pause(_ delay: TimeInterval, deadline: TimeInterval) async throws {
        let interval = min(delay, max(0, deadline - now))
        if interval > 0 { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
    }
    private func readOnce(_ register: Int, serial: String, deadline: TimeInterval) throws -> Int {
        let text = try command(["read", serial, String(format: "0x%02X", register)], deadline: deadline)
        guard let value = Int(text), RegisterValue.isValid(value, register: register) else {
            throw ControlError.message("Monitor is reconnecting; invalid response for \(String(format: "0x%02X", register)): \(text)")
        }
        return value
    }
    private func statusOnce(serial: String, deadline: TimeInterval) throws -> MonitorStatus {
        let mode = try readOnce(0xe9, serial: serial, deadline: deadline) & 0xff
        let source = try readOnce(0x60, serial: serial, deadline: deadline)
        let secondary = mode == 0 ? nil : VideoInput(code: try readOnce(0xe8, serial: serial, deadline: deadline) & 0xff)
        // Reject a sample spanning a layout change instead of reporting a mixed snapshot.
        guard mode == (try readOnce(0xe9, serial: serial, deadline: deadline) & 0xff), let main = VideoInput(code: source & 0xff) else {
            throw ControlError.message("Monitor layout changed while reading its state.")
        }
        return MonitorStatus(mode: mode, main: main, secondary: secondary, localInput: VideoInput(code: source >> 8 & 0xff))
    }
    func discover() throws -> [ConnectedMonitor] { try ConnectedMonitor.decode(command(["list"], deadline: now + timing.discovery)) }
    func status(serial: String) async throws -> MonitorStatus { try await readStatus(serial: serial, deadline: now + timing.discovery) }
    private func readStatus(serial: String, deadline: TimeInterval) async throws -> MonitorStatus {
        var last: Error = ControlError.message("Monitor unavailable.")
        while now < deadline {
            do { return try statusOnce(serial: serial, deadline: deadline) } catch { last = error }
            try await pause(timing.poll, deadline: deadline)
        }
        throw ControlError.message("Could not read monitor before the time limit: \(last.localizedDescription)")
    }
    private func waitFor(_ action: RegisterWrite, serial: String, deadline: TimeInterval, isCurrent: @escaping @Sendable () async -> Bool) async throws {
        var confirmations = 0
        var last = "Monitor unavailable"
        while now < deadline {
            do {
                let actual = try readOnce(action.register, serial: serial, deadline: deadline) & 0xff
                if !(await isCurrent()) { return }
                confirmations = actual == action.value ? confirmations + 1 : 0
                last = String(format: "register 0x%02X is 0x%02X, expected 0x%02X", action.register, actual, action.value)
                if confirmations >= 2 { return }
            } catch { confirmations = 0; last = error.localizedDescription }
            try await pause(timing.poll, deadline: deadline)
        }
        throw ControlError.message("Timed out after \(action.label.lowercased()): \(last). Some settings may have changed; retry verification.")
    }
    func apply(_ preset: DisplayPreset, configuration: AppConfiguration, request: UUID,
               isCurrent: @escaping @Sendable () async -> Bool,
               progress: @escaping @Sendable (String) async -> Void) async throws -> ApplyResult {
        guard configuration.inputConfirmed, !configuration.monitorSerial.isEmpty else { throw ControlError.message("Select your monitor and confirm this Mac's input first.") }
        try preset.validate()
        if configuration.keepLocalVisible && !preset.includes(configuration.localInput) { throw ControlError.message("This preset would hide this Mac.") }
        requestID = request; defer { requestID = nil }
        let start = now, deadline = start + timing.transition, serial = configuration.monitorSerial
        await progress("Reading current layout and inputs")
        let before = try await readStatus(serial: serial, deadline: deadline)
        guard await isCurrent() else { return .superseded }
        let actions = try TransitionPlanner.plan(preset, current: before, local: configuration.localInput, keepVisible: configuration.keepLocalVisible)
        journal.record("plan", request: request, fields: ["preset": preset.name, "before": before.description, "writes": actions.map { ["register": $0.register, "value": $0.value] }])
        if before.matches(preset) { return .verified(before) }
        for (index, action) in actions.enumerated() {
            guard await isCurrent() else { return .superseded }
            await progress("\(index + 1)/\(actions.count) · \(action.label)")
            // An I/O error can be ambiguous. Read back before retrying a write.
            var sent = false
            var lastError: Error = ControlError.message("Monitor unavailable.")
            while now < deadline && !sent {
                guard await isCurrent() else { return .superseded }
                do {
                    _ = try command(["write", serial, String(format: "0x%02X", action.register), String(format: "0x%02X", action.value)], deadline: deadline)
                    sent = true
                } catch {
                    lastError = error
                    if let value = try? readOnce(action.register, serial: serial, deadline: deadline), value & 0xff == action.value { sent = true }
                    else { try await pause(timing.poll, deadline: deadline) }
                }
            }
            guard sent else { throw ControlError.message("Write did not complete before the time limit: \(lastError.localizedDescription)") }
            // The final visibility-removing write cannot be verified on the video transport.
            if index == actions.count - 1 && !preset.includes(configuration.localInput) { return .unverified }
            try await pause(timing.initialSettle, deadline: deadline)
            try await waitFor(action, serial: serial, deadline: deadline, isCurrent: isCurrent)
            guard await isCurrent() else { return .superseded }
        }
        await progress("Verifying layout and inputs")
        var last: MonitorStatus?
        var confirmations = 0
        while now < deadline {
            guard await isCurrent() else { return .superseded }
            do {
                let after = try statusOnce(serial: serial, deadline: deadline)
                last = after
                confirmations = after.matches(preset) ? confirmations + 1 : 0
                if confirmations >= 2 {
                    journal.record("readback", request: request, fields: ["state": after.description, "ms": Int((now - start) * 1000)])
                    return .verified(after)
                }
            } catch { confirmations = 0 }
            try await pause(timing.poll, deadline: deadline)
        }
        throw ControlError.message("Preset was not verified before the time limit. Last readback: \(last?.description ?? "unavailable"). Retry verification or choose another preset.")
    }
}
