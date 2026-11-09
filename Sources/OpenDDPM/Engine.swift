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
    func setPower(_ on: Bool, serial: String) async throws
    func apply(_ preset: DisplayPreset, configuration: AppConfiguration, request: UUID,
               isCurrent: @escaping @Sendable () async -> Bool,
               progress: @escaping @Sendable (String) async -> Void) async throws -> ApplyResult
}

actor MonitorEngine: MonitorControlling {
    private var nativeBrightnessBinding: (serial: String, displayID: UInt32)?
    private let nativeBrightness: NativeBrightnessControlling
    private let transport: MonitorTransport
    private let timing: EngineTiming
    private let journal: TransitionJournal
    private var requestID: UUID?
    init(helper: URL) { nativeBrightness = NativeBrightnessBridge(); transport = HelperRunner(executable: helper); timing = EngineTiming(); journal = .standard }
    init(transport: MonitorTransport, timing: EngineTiming, journal: TransitionJournal, nativeBrightness: NativeBrightnessControlling = NativeBrightnessBridge()) {
        self.nativeBrightness = nativeBrightness
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
        let power = (try? readOnce(0xd6, serial: serial, deadline: deadline)) ?? 1
        return MonitorStatus(mode: mode, main: main, secondary: secondary, localInput: VideoInput(code: source >> 8 & 0xff), power: power & 0xff)
    }
    func setPower(_ on: Bool, serial: String) async throws {
        let deadline = now + timing.command
        let code = on ? 1 : 4
        _ = try command(["write", serial, "0xD6", String(format: "0x%02X", code)], deadline: deadline)
        journal.record("power-write", fields: ["serial": serial, "power": code])
    }
    // Picture operations stay on the same actor as input/layout commands.
    private func nativeBrightnessTarget(serial: String, displayID: UInt32?) throws -> UInt32? {
        guard let displayID, nativeBrightness.supports(displayID) else { return nil }
        // CG IDs can be reused on reconnection. Revalidate against the same serial
        // immediately before native access, rather than touching another display.
        let matches = try discover().filter { $0.serial == serial }
        guard matches.count == 1, matches[0].displayID == displayID else {
            throw ControlError.message("The selected monitor reconnected. Refresh monitor discovery before adjusting brightness.")
        }
        nativeBrightnessBinding = (serial, displayID)
        return displayID
    }
    /// Read-only sampling for visible controls. Identity was established by a
    /// serial-bound discovery; this path performs no helper/DDC transactions.
    func sampleNativeBrightness(serial: String, displayID: UInt32) throws -> Double? {
        guard let binding = nativeBrightnessBinding, binding.serial == serial,
              binding.displayID == displayID, nativeBrightness.supports(displayID) else { return nil }
        return try nativeBrightness.readPrecise(displayID)
    }
    func readPicture(_ register: Int, serial: String, displayID: UInt32? = nil) throws -> Int {
        if register == 0x10, let target = try nativeBrightnessTarget(serial: serial, displayID: displayID) {
            let value = try nativeBrightness.read(target)
            journal.record("native-brightness-read", fields: ["serial": serial, "displayID": target, "value": value])
            return value
        }
        let value = try readOnce(register, serial: serial, deadline: now + timing.command)
        return register == 0xE2 ? value & 0xff : value
    }
    /// Send a keyboard target promptly. The controls worker verifies the final
    /// target after the key burst; the transport acknowledgement is not readback.
    func sendBrightness(_ value: Int, serial: String, displayID: UInt32?) throws {
        guard PictureFeature.brightness.accepts(value) else { throw ControlError.message("Unsupported brightness value.") }
        if let target = try nativeBrightnessTarget(serial: serial, displayID: displayID) {
            try nativeBrightness.write(value, displayID: target)
            journal.record("native-brightness-write", fields: ["serial": serial, "displayID": target, "value": value])
        } else {
            _ = try command(["write", serial, "0x10", String(value)], deadline: now + timing.command)
        }
        journal.record("brightness-sent", fields: ["serial": serial, "value": value, "uptimeMS": Int(now * 1000)])
    }
    func writePicture(_ register: Int, value requestedValue: Int, serial: String, mask: Int = 0xffff, displayID: UInt32? = nil) throws -> Int {
        var value = requestedValue
        if register == 0x66 {
            guard mask == 3 || mask == 0xc0 else { throw ControlError.message("Invalid automatic brightness field.") }
            let before = try readPicture(register, serial: serial)
            value = (before & ~mask) | (requestedValue & mask)
        } else if mask != 0xffff { throw ControlError.message("Invalid monitor setting mask.") }
        guard PictureFeature.all.contains(where: { $0.register == register && $0.accepts(value) }) else {
            throw ControlError.message("Unsupported monitor setting or value.")
        }
        if register == 0x10, let target = try nativeBrightnessTarget(serial: serial, displayID: displayID) {
            try nativeBrightness.write(value, displayID: target)
            journal.record("native-brightness-write", fields: ["serial": serial, "displayID": target, "value": value])
            let deadline = now + 2
            var confirmations = 0
            while now < deadline {
                let actual = try nativeBrightness.read(target)
                confirmations = actual == value ? confirmations + 1 : 0
                if confirmations >= 2 {
                    journal.record("native-brightness-verified", fields: ["serial": serial, "displayID": target, "value": actual])
                    return actual
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw ControlError.message("macOS did not confirm the requested brightness. Refresh monitor settings and retry.")
        }
        let deadline = now + timing.discovery
        let output = register == 0xE2 ? PictureFeature.colorCommand(value)! : (register: register, value: value)
        _ = try command(["write", serial, String(format: "0x%02X", output.register), String(output.value)], deadline: deadline)
        // Let the monitor settle before reading; the acknowledgement alone is not verification.
        Thread.sleep(forTimeInterval: 0.2)
        let verificationRegister = output.register
        let expected = output.value
        var confirmations = 0
        var last = "No valid reply."
        while now < deadline {
            do {
                let actual = try readOnce(verificationRegister, serial: serial, deadline: deadline)
                confirmations = actual == expected ? confirmations + 1 : 0
                last = "Monitor returned \(actual) after requesting \(expected)."
                if confirmations >= 2 { return register == 0xE2 ? value : actual }
            } catch {
                // Secondary PBP inputs can temporarily stop replying after a
                // successful write. Retry reads only; never resend the write.
                last = error.localizedDescription
            }
            let remaining = deadline - now
            if remaining > 0 { Thread.sleep(forTimeInterval: min(0.25, remaining)) }
        }
        throw ControlError.message("Monitor setting was not confirmed before the time limit. \(last) Refresh its settings before retrying.")
    }
    func prepareHDR(_ enabled: Bool, serial: String) throws {
        // DDPM sends this command but reads HDR state through MPDisplay, not EA.
        _ = try command(["write", serial, "0xEA", enabled ? "0xFE01" : "0xFE00"], deadline: now + timing.command)
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
        if before.power == 4 {
            _ = try? command(["write", serial, "0xD6", "0x01"], deadline: deadline)
            try await pause(timing.initialSettle, deadline: deadline)
        }
        if before.matches(preset) && before.power != 4 { return .verified(before) }
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
