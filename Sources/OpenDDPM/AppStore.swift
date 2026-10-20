import AppKit
import Combine
import ServiceManagement
import CoreGraphics

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
    @Published var transition = TransitionState()
    let coordinator: PresetCoordinator
    let launcher = HotkeyManager()
    var openRemote: (() -> Void)?
    var previousPreset: DisplayPreset? { configuration.presets.first { $0.id == transition.previousPresetID } }
    let engine: MonitorEngine
    let configurationURL: URL
    var openWindow: (() -> Void)?
    var helperURL: URL
    let hotkeys = HotkeyManager()
    let homekit = HomeKitManager()
    private var recordingShortcut = false
    private var systemObservers: [NSObjectProtocol] = []

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
        let monitorEngine = MonitorEngine(helper: helperURL)
        engine = monitorEngine
        coordinator = PresetCoordinator(engine: monitorEngine)
        error = loadError
        hotkeys.onPress = { [weak self] id in
            guard let self, let preset = self.configuration.presets.first(where: { $0.id == id }) else { return }
            self.apply(preset)
        }
        coordinator.onChange = { [weak self] in self?.synchronizeState() }
        launcher.onPress = { [weak self] _ in self?.openRemote?() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.coordinator.setAvailability("Mac is asleep or locked. Wake and unlock it, then retry verification.") }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeControl() }
            })
        }
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.coordinator.setAvailability("Mac is locked. Unlock it, then retry verification.") }
        })
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeControl() }
        })
        if Self.screenLocked { coordinator.setAvailability("Mac is locked. Unlock it, then retry verification.") }
        updateHotkeys()
    }
    private static var screenLocked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true }
    private func resumeControl() {
        guard !Self.screenLocked else { return }
        coordinator.setAvailability(nil)
        refresh()
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
        let remote = DisplayPreset(id: Self.remoteID, name: "Preset remote", layout: .full, main: .dp, secondary: .hdmi, shortcut: configuration.effectiveRemoteShortcut)
        let issues = launcher.synchronize(recordingShortcut ? [] : [remote])
        if let issue = issues[Self.remoteID] { hotkeyIssues[Self.remoteID] = issue }
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
    static let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    func synchronizeState() {
        transition = coordinator.state
        busy = coordinator.busy
        progress = transition.progress
        status = transition.monitor
        lastPresetID = transition.observedAt == nil ? nil : transition.verifiedPresetID
        monitors = coordinator.monitors.filter { $0.name.contains("U4025QW") }
        if configuration.monitorSerial.isEmpty, let first = monitors.first {
            configuration.monitorSerial = first.serial; configuration.monitorName = first.name
        }
        if !configuration.inputConfirmed, let detected = status?.localInput { configuration.localInput = detected }
    }
    func refresh(quietly: Bool = false) { coordinator.refresh(configuration: configuration, quietly: quietly) }
    func previous() {
        guard let preset = previousPreset else { return }
        apply(preset)
    }
    func setRemoteShortcut(_ shortcut: PresetShortcut) {
        do { var candidate = configuration; candidate.remoteShortcut = shortcut; try candidate.validate(); configuration = candidate }
        catch { self.error = error.localizedDescription }
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
    @discardableResult
    func request(_ preset: DisplayPreset) throws -> UUID {
        let id = try coordinator.submit(preset, configuration: configuration)
        error = nil
        return id
    }
    func apply(_ preset: DisplayPreset) {
        guard configured else { selectedPage = "setup"; openWindow?(); return }
        do { _ = try request(preset); error = nil }
        catch { self.error = error.localizedDescription }
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
