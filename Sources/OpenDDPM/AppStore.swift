import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    @Published var configuration: AppConfiguration { didSet { persist() } }
    @Published var monitors: [ConnectedMonitor] = []
    @Published var status: MonitorStatus?
    @Published var busy = false
    @Published var progress = "Ready"
    @Published var error: String?
    @Published var selectedPage = "setup"
    @Published var hotkeyIssues: [UUID: String] = [:]
    @Published var lastPresetID: UUID?
    let engine: MonitorEngine
    let configurationURL: URL
    var openWindow: (() -> Void)?
    var helperURL: URL
    let hotkeys = HotkeyManager()
    private var recordingShortcut = false

    init() {
        configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDDPM/configuration.json")
        var loaded = AppConfiguration()
        var loadError: String?
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do { loaded = try ConfigurationFile.load(configurationURL) }
            catch {
                let backup = configurationURL.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at: configurationURL, to: backup); loadError = "Saved configuration could not be read. A backup is preserved at \(backup.path)." }
                catch { loadError = "Saved configuration could not be read or backed up: \(error.localizedDescription)" }
            }
        }
        configuration = loaded
        helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openddpm-ddc")
        engine = MonitorEngine(helper: helperURL)
        error = loadError
        hotkeys.onPress = { [weak self] id in
            guard let self, let preset = self.configuration.presets.first(where: { $0.id == id }) else { return }
            self.apply(preset)
        }
        updateHotkeys()
    }
    var configured: Bool { !configuration.monitorSerial.isEmpty && configuration.inputConfirmed }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func persist() {
        do { try ConfigurationFile.save(configuration, to: configurationURL) }
        catch { self.error = "Could not save configuration: \(error.localizedDescription)" }
        updateHotkeys()
    }
    func updateHotkeys() {
        let enabled = configured && !recordingShortcut ? configuration.presets.filter { !configuration.keepLocalVisible || $0.includes(configuration.localInput) } : []
        hotkeyIssues = hotkeys.synchronize(enabled)
    }
    func shortcutRecording(_ active: Bool) { recordingShortcut = active; updateHotkeys() }
    func setShortcut(_ shortcut: PresetShortcut?, for id: UUID) {
        guard !busy, let index = configuration.presets.firstIndex(where: { $0.id == id }) else { return }
        do {
            var candidate = configuration; candidate.presets[index].shortcut = shortcut
            try candidate.validate()
            configuration = candidate
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard !busy else { return }
        busy = true; error = nil; progress = "Finding connected monitors"
        Task {
            do {
                let discovered = try await engine.discover()
                monitors = discovered.filter { $0.model.contains("U4025QW") || $0.name.contains("U4025QW") }
                if configuration.monitorSerial.isEmpty, let first = monitors.first {
                    configuration.monitorSerial = first.serial
                    configuration.monitorName = first.name
                }
                guard monitors.contains(where: { $0.serial == configuration.monitorSerial }) else { throw ControlError.message("No selected U4025QW was found. Connect your monitor and enable DDC/CI in its on-screen menu.") }
                progress = "Reading layout and inputs"
                let current = try await engine.status(serial: configuration.monitorSerial)
                status = current
                lastPresetID = configuration.presets.first(where: { current.matches($0) })?.id
                if !configuration.inputConfirmed, let detected = current.localInput { configuration.localInput = detected }
                progress = current.description
            } catch { self.error = error.localizedDescription; progress = "Connection needs attention" }
            busy = false
        }
    }
    func selectMonitor(_ serial: String) {
        guard !busy else { return }
        configuration.monitorSerial = serial
        configuration.monitorName = monitors.first { $0.serial == serial }?.name ?? "Monitor"
        configuration.inputConfirmed = false
        status = nil
        refresh()
    }
    func confirmInput() { configuration.inputConfirmed = true; selectedPage = "presets" }
    func apply(_ preset: DisplayPreset) {
        guard !busy else { return }
        guard configured else { selectedPage = "setup"; openWindow?(); return }
        if configuration.keepLocalVisible && !preset.includes(configuration.localInput) {
            error = "This preset hides this Mac's \(configuration.localInput.title) input. Change ‘Keep this Mac visible’ in Setup to allow it."
            openWindow?(); return
        }
        busy = true; error = nil; lastPresetID = nil; status = nil; progress = "Preparing \(preset.name)"
        let snapshot = configuration
        Task {
            do {
                let result = try await engine.apply(preset, configuration: snapshot) { [self] text in
                    await MainActor.run { self.progress = text }
                }
                status = result
                lastPresetID = preset.id
                progress = result == nil ? "Applied \(preset.name) · this Mac is hidden; readback unavailable" : "Applied \(preset.name) · verified"
            } catch { self.error = error.localizedDescription; progress = "Preset could not be verified" }
            busy = false
        }
    }
    func savePreset(_ preset: DisplayPreset) {
        do {
            try preset.validate()
            if let index = configuration.presets.firstIndex(where: { $0.id == preset.id }) { configuration.presets[index] = preset }
            else { configuration.presets.append(preset) }
        } catch { self.error = error.localizedDescription }
    }
    func deletePreset(_ id: UUID) { configuration.presets.removeAll { $0.id == id } }
    func movePreset(_ id: UUID, by offset: Int) {
        guard let index = configuration.presets.firstIndex(where: { $0.id == id }), configuration.presets.indices.contains(index + offset) else { return }
        configuration.presets.swapAt(index, index + offset)
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OpenDDPM-presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ConfigurationFile.save(configuration, to: url) } catch { self.error = error.localizedDescription }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ConfigurationFile.load(url)
            // Share presets between Macs without copying the other Mac's input assignment.
            configuration.presets = imported.presets
        } catch { self.error = "Could not import presets: \(error.localizedDescription)" }
    }
    func toggleLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; objectWillChange.send() }
        catch { self.error = "Login launch could not be changed: \(error.localizedDescription). Move OpenDDPM to Applications first." }
    }
}
