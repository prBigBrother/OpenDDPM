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
    var shortcut: PresetShortcut? = nil
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
    var remoteShortcut: PresetShortcut? = nil
    var effectiveRemoteShortcut: PresetShortcut { remoteShortcut ?? PresetShortcut(keyCode: 49, modifiers: PresetShortcut.control | PresetShortcut.option, keyLabel: "Space") }
    func validate() throws {
        guard schemaVersion == 1 else { throw ControlError.message("This configuration uses an unsupported format.") }
        guard !monitorSerial.contains("\n"), monitorSerial.count < 200, presets.count <= 100 else { throw ControlError.message("Invalid monitor or preset data.") }
        guard Set(presets.map(\.id)).count == presets.count else { throw ControlError.message("Preset IDs must be unique.") }
        for preset in presets { try preset.validate() }
        let shortcuts = presets.compactMap(\.shortcut) + [remoteShortcut].compactMap { $0 }
        for shortcut in shortcuts { try shortcut.validate() }
        guard Set(shortcuts.map(\.identity)).count == shortcuts.count else { throw ControlError.message("Presets and the remote must use different hotkeys.") }
    }
}

struct ConnectedMonitor: Identifiable, Equatable {
    var serial: String
    var name: String
    var model: String
    var id: String { serial }
    static func decode(_ text: String) throws -> [Self] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rows = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] else { throw ControlError.message("Unexpected monitor list from native DDC.") }
        return rows.compactMap { row in
            guard let serial = row["serial"] as? String, !serial.isEmpty else { return nil }
            return Self(serial: serial, name: row["name"] as? String ?? "Monitor", model: row["model"] as? String ?? "")
        }
    }
}

struct MonitorStatus: Codable, Equatable {
    var mode: Int
    var main: VideoInput
    var secondary: VideoInput?
    var localInput: VideoInput?
    var power: Int? = 1
    var isPoweredOn: Bool { power != 4 }
    var layout: SplitLayout? { SplitLayout.allCases.first { $0.code == mode } }
    var description: String {
        let base = "\(layout?.title ?? String(format: "Mode 0x%02X", mode)) · \(main.short)" + (mode != 0 ? " + \(secondary?.short ?? "?")" : "")
        return power == 4 ? "\(base) · Standby" : base
    }
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
        if register == 0xd6 { return [1, 2, 3, 4, 5].contains(value & 0xff) }
        return true
    }
}

enum TransitionPlanner {
    static func plan(_ preset: DisplayPreset, current: MonitorStatus, local: VideoInput, keepVisible: Bool) throws -> [RegisterWrite] {
        let sequence = try requiredSequence(preset, currentMain: current.main, local: local, keepVisible: keepVisible)
        var main = current.main
        var secondary = current.secondary
        var mode = current.mode
        var actions: [RegisterWrite] = []
        for action in sequence {
            switch action.register {
            case 0xe9:
                guard mode != action.value else { continue }
                mode = action.value
            case 0x60:
                guard let input = VideoInput(code: action.value), main != input else { continue }
                // Dell automatically swaps regions when selecting the secondary as main.
                if secondary == input { secondary = main }
                main = input
            case 0xe8:
                guard let input = VideoInput(code: action.value), secondary != input, main != input else { continue }
                secondary = input
            default: break
            }
            actions.append(action)
        }
        return actions
    }

    private static func requiredSequence(_ preset: DisplayPreset, currentMain: VideoInput, local: VideoInput, keepVisible: Bool) throws -> [RegisterWrite] {
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
