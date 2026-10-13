import Foundation

enum VideoInput: String, Codable, CaseIterable, Identifiable {
    case dp, hdmi, thunderbolt
    var id: String { rawValue }
    var title: String { switch self { case .dp: return "DisplayPort"; case .hdmi: return "HDMI"; case .thunderbolt: return "Thunderbolt" } }
    var short: String { self == .dp ? "DP" : self == .hdmi ? "HDMI" : "TB" }
    var code: Int { self == .dp ? 0x0f : self == .hdmi ? 0x11 : 0x19 }
    init?(code: Int) { guard let input = Self.allCases.first(where: { $0.code == code }) else { return nil }; self = input }
}

enum SplitLayout: String, Codable, CaseIterable, Identifiable {
    case full, equal, largeLeft, largeRight, pipSmall, pipLarge
    var id: String { rawValue }
    var title: String {
        switch self { case .full: return "Full screen"; case .equal: return "50 / 50"; case .largeLeft: return "75 / 25"; case .largeRight: return "25 / 75"; case .pipSmall: return "Picture in Picture · Small"; case .pipLarge: return "Picture in Picture · Large" }
    }
    var code: Int { switch self { case .full: return 0; case .equal: return 0x24; case .largeLeft: return 0x2a; case .largeRight: return 0x29; case .pipSmall: return 0x21; case .pipLarge: return 0x22 } }
    var fraction: Double { self == .equal ? 0.5 : self == .largeRight ? 0.25 : 0.75 }
    var isPIP: Bool { self == .pipSmall || self == .pipLarge }
}

struct DisplayPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: SplitLayout
    var main: VideoInput
    var secondary: VideoInput
    func includes(_ input: VideoInput) -> Bool { main == input || (layout != .full && secondary == input) }
    var detail: String { layout == .full ? main.title : "\(main.short) + \(secondary.short) · \(layout.title)" }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ControlError.message("Give this preset a name.") }
        if layout != .full && main == secondary { throw ControlError.message("Choose two different inputs for a split layout.") }
    }
    static var defaults: [Self] {
        [Self(name: "Two desks", layout: .equal, main: .thunderbolt, secondary: .dp),
         Self(name: "HDMI focus", layout: .largeLeft, main: .hdmi, secondary: .thunderbolt),
         Self(name: "DP focus", layout: .largeLeft, main: .dp, secondary: .thunderbolt),
         Self(name: "HDMI only", layout: .full, main: .hdmi, secondary: .dp),
         Self(name: "Thunderbolt only", layout: .full, main: .thunderbolt, secondary: .dp),
         Self(name: "DP only", layout: .full, main: .dp, secondary: .thunderbolt)]
    }
}

struct AppConfiguration: Codable {
    var schemaVersion = 1
    var monitorSerial = ""
    var monitorName = ""
    var localInput: VideoInput = .dp
    var inputConfirmed = false
    var keepLocalVisible = true
    var presets = DisplayPreset.defaults
    func validate() throws {
        guard schemaVersion == 1 else { throw ControlError.message("This configuration uses an unsupported format.") }
        guard !monitorSerial.contains("\n"), monitorSerial.count < 200, presets.count <= 100 else { throw ControlError.message("Invalid monitor or preset data.") }
        guard Set(presets.map(\.id)).count == presets.count else { throw ControlError.message("Preset IDs must be unique.") }
        for preset in presets { try preset.validate() }
    }
}

struct ConnectedMonitor: Identifiable, Equatable {
    var serial: String
    var name: String
    var model: String
    var id: String { serial }
    static func decode(_ text: String) throws -> [Self] {
        // BetterDisplay returns comma-separated JSON objects, rather than a JSON array.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed.hasPrefix("[") ? trimmed : "[" + trimmed + "]"
        guard let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { throw ControlError.message("Unexpected monitor list from BetterDisplay.") }
        return rows.compactMap { row in
            guard row["deviceType"] as? String == "Display", let serial = row["alphanumericSerial"] as? String, !serial.isEmpty else { return nil }
            return Self(serial: serial, name: row["name"] as? String ?? "Monitor", model: row["productName"] as? String ?? "")
        }
    }
}

struct MonitorStatus {
    var mode: Int
    var main: VideoInput
    var secondary: VideoInput?
    var localInput: VideoInput?
    var layout: SplitLayout? { SplitLayout.allCases.first { $0.code == mode } }
    var description: String { "\(layout?.title ?? String(format: "Mode 0x%02X", mode)) · \(main.short)" + (mode != 0 ? " + \(secondary?.short ?? "?")" : "") }
    func matches(_ preset: DisplayPreset) -> Bool { mode == preset.layout.code && main == preset.main && (mode == 0 || secondary == preset.secondary) }
}

enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

struct RegisterWrite: Equatable {
    var register: Int
    var value: Int
    var label: String
}

enum RegisterValue {
    static func isValid(_ value: Int, register: Int) -> Bool {
        guard (0...65535).contains(value) else { return false }
        if register == 0x60 || register == 0xe8 { return VideoInput(code: value & 0xff) != nil }
        if register == 0xe9 { return [0, 1, 2, 0x21, 0x22, 0x24, 0x27, 0x28, 0x29, 0x2a].contains(value & 0xff) }
        return true
    }
}

enum TransitionPlanner {
    static func plan(_ preset: DisplayPreset, currentMain: VideoInput, local: VideoInput, keepVisible: Bool) throws -> [RegisterWrite] {
        try preset.validate()
        if keepVisible && !preset.includes(local) { throw ControlError.message("This preset hides this Mac's \(local.title) input. Turn off ‘Keep this Mac visible’ in Setup to allow it.") }
        let source: (VideoInput) -> RegisterWrite = { RegisterWrite(register: 0x60, value: $0.code, label: "Selecting \($0.title)") }
        let sub: (VideoInput) -> RegisterWrite = { RegisterWrite(register: 0xe8, value: $0.code, label: "Setting secondary input to \($0.title)") }
        let mode = RegisterWrite(register: 0xe9, value: preset.layout.code, label: "Applying \(preset.layout.title) layout")
        if !preset.includes(local) {
            // Prepare everything while the control Mac is visible. Hide it only on the final write.
            return [source(local), mode] + (preset.layout == .full ? [] : [sub(preset.secondary)]) + [source(preset.main)]
        }
        if preset.layout == .full { return [source(preset.main), mode] }
        if currentMain == preset.secondary {
            // Firmware ignores main == sub. Stage the new main in sub, then let firmware swap.
            return [mode, sub(preset.main), source(preset.main), sub(preset.secondary)]
        }
        return [mode, source(preset.main), sub(preset.secondary)]
    }
}

struct HelperRunner {
    let executable: URL
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw ControlError.message("The bundled BetterDisplay CLI helper could not start: \(error.localizedDescription)") }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !output.hasPrefix("Failed.") else {
            throw ControlError.message(output.isEmpty ? "BetterDisplay did not respond. Start BetterDisplay and enable CLI / notification integration in its settings." : output)
        }
        return output
    }
}

actor MonitorEngine {
    let runner: HelperRunner
    init(helper: URL) { runner = HelperRunner(executable: helper) }
    func discover() throws -> [ConnectedMonitor] { try ConnectedMonitor.decode(runner.run(["get", "-identifiers", "-type=Display"])) }
    func read(_ register: Int, serial: String) async throws -> Int {
        var lastError: Error = ControlError.message("Monitor unavailable.")
        for attempt in 0..<10 {
            do {
                let text = try runner.run(["get", "-alphanumericSerial=\(serial)", "-ddc", String(format: "-vcp=0x%02X", register)])
                guard let value = Int(text), RegisterValue.isValid(value, register: register) else { throw ControlError.message("Monitor is still reconnecting; unexpected register response: \(text)") }
                return value
            } catch { lastError = error }
            if attempt < 9 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw lastError
    }
    func status(serial: String) async throws -> MonitorStatus {
        let mode = try await read(0xe9, serial: serial) & 0xff
        let source = try await read(0x60, serial: serial)
        guard let main = VideoInput(code: source & 0xff) else { throw ControlError.message("This monitor reports an unsupported main input.") }
        let secondary = mode == 0 ? nil : VideoInput(code: try await read(0xe8, serial: serial) & 0xff)
        return MonitorStatus(mode: mode, main: main, secondary: secondary, localInput: VideoInput(code: source >> 8 & 0xff))
    }
    func write(_ action: RegisterWrite, serial: String) async throws {
        var lastError: Error = ControlError.message("Monitor unavailable.")
        for attempt in 0..<10 {
            do {
                _ = try runner.run(["set", "-alphanumericSerial=\(serial)", String(format: "-vcp=0x%02X", action.register), String(format: "-ddc=0x%02X", action.value)])
                return
            } catch { lastError = error }
            if attempt < 9 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw lastError
    }
    func apply(_ preset: DisplayPreset, configuration: AppConfiguration, progress: @escaping @Sendable (String) async -> Void) async throws -> MonitorStatus? {
        guard configuration.inputConfirmed, !configuration.monitorSerial.isEmpty else { throw ControlError.message("Select your monitor and identify this Mac's input in Setup first.") }
        // Validate before issuing any writes.
        try preset.validate()
        if configuration.keepLocalVisible && !preset.includes(configuration.localInput) { throw ControlError.message("This preset would hide this Mac. Check ‘Keep this Mac visible’ in Setup.") }
        let before = try await status(serial: configuration.monitorSerial)
        let actions = try TransitionPlanner.plan(preset, currentMain: before.main, local: configuration.localInput, keepVisible: configuration.keepLocalVisible)
        if before.matches(preset) { return before }
        for (index, action) in actions.enumerated() {
            await progress("\(index + 1)/\(actions.count) · \(action.label)")
            try await write(action, serial: configuration.monitorSerial)
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        if !preset.includes(configuration.localInput) { return nil }
        await progress("Checking monitor readback")
        var lastStatus: MonitorStatus?
        for attempt in 0..<3 {
            let after = try await status(serial: configuration.monitorSerial)
            if after.matches(preset) { return after }
            lastStatus = after
            if attempt < 2 { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        throw ControlError.message("Monitor readback differs from the preset: \(lastStatus?.description ?? "unavailable"). Refresh status and retry.")
    }
}

enum ConfigurationFile {
    static func load(_ url: URL) throws -> AppConfiguration {
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }
    static func save(_ configuration: AppConfiguration, to url: URL) throws {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}
