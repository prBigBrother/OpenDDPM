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
    @Published var isDisplaySleeping = false
    let coordinator: PresetCoordinator
    var previousPreset: DisplayPreset? { transition.previousPreset(in: configuration) }
    let engine: MonitorEngine
    let monitorControls = MonitorControls()
    let monitorHDR = MonitorHDR()
    let brightnessKeys = BrightnessKeyController()
    let brightnessOSD = BrightnessOSD()
    let configurationURL: URL
    var openWindow: (() -> Void)?
    var quitApplication: (() -> Void)?
    var helperURL: URL
    let hotkeys = HotkeyManager()
    let homekit = HomeKitManager()
    private var recordingShortcut = false
    private var systemObservers: [NSObjectProtocol] = []
    private var availabilityTimer: Timer?
    private var systemSleeping = false

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
        coordinator.availabilityProvider = { [weak self] in
            guard let self else { return "Mac session is unavailable. Wake and unlock it, then retry verification." }
            return self.sessionUnavailableReason
        }
        error = loadError
        hotkeys.onPress = { [weak self] id in
            guard let self, let preset = self.configuration.presets.first(where: { $0.id == id }) else { return }
            self.apply(preset)
        }
        coordinator.wakeConfigurationProvider = { [weak self] in self?.configuration.wakeup }
        coordinator.beforeTransition = { [weak self] in
            while self?.monitorControls.working == true || self?.monitorHDR.busy == true {
                do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
            }
        }
        coordinator.onChange = { [weak self] in self?.synchronizeState() }
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDisplaySleeping = true
                self?.objectWillChange.send()
            }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if name == NSWorkspace.willSleepNotification { self?.systemSleeping = true }
                    self?.coordinator.setAvailability("Mac is asleep or locked. Wake and unlock it, then retry verification.")
                }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isDisplaySleeping = false
                    self?.systemSleeping = false
                    self?.resumeControl()
                }
            })
        }
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.setAvailability("Mac is locked. Unlock it, then retry verification.") }
        })
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeControl() }
        })
        coordinator.setAvailability(sessionUnavailableReason)
        systemObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverSessionAvailability() }
        })
        // Unlock notifications can arrive before CGSession updates, or be missed
        // altogether. Reconcile only a suspended session; never replay commands.
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverSessionAvailability() }
        }
        systemObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMonitorHDR() }
        })
        updateHotkeys()
        connectMonitorControls()
        brightnessKeys.canHandle = { [weak self] in
            guard let self else { return false }
            return self.monitorControls.canAcceptChanges && self.monitorControls.displayedBrightness != nil && self.monitorControls.canAdjustBrightness
        }
        brightnessKeys.onStep = { [weak self] in self?.monitorControls.stepBrightness($0) }
        brightnessKeys.onDiagnostic = { decision in
            let uptimeMS = Int(ProcessInfo.processInfo.systemUptime * 1000)
            Task { @MainActor in TransitionJournal.standard.record("brightness-key", fields: ["decision": decision, "uptimeMS": uptimeMS]) }
        }
        monitorControls.onBrightnessRequested = { [weak self] value in
            guard let self, self.brightnessKeys.isEnabled,
                  let id = self.monitors.first(where: { $0.serial == self.configuration.monitorSerial })?.displayID else { return }
            // Return from the event tap before creating/updating any HUD window.
            Task { @MainActor [weak self] in self?.brightnessOSD.show(value: Double(value), displayID: id) }
        }
        brightnessKeys.restore()
    }
    private var sessionUnavailableReason: String? {
        guard !systemSleeping,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "Mac is asleep or locked. Wake and unlock it, then retry verification."
        }
        return nil
    }
    private var sessionAllowsControl: Bool { sessionUnavailableReason == nil }
    private func recoverSessionAvailability() {
        guard transition.phase == "unavailable", sessionAllowsControl else { return }
        resumeControl()
    }
    private func resumeControl() {
        guard sessionAllowsControl else { return }
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
    }
    func shortcutRecording(_ active: Bool) { recordingShortcut = active; updateHotkeys() }
    func setShortcut(_ shortcut: PresetShortcut?, for id: UUID) {
        guard let index = configuration.presets.firstIndex(where: { $0.id == id }) else { return }
        do {
            var candidate = configuration; candidate.presets[index].shortcut = shortcut
            try candidate.validate()
            configuration = candidate
        } catch { self.error = error.localizedDescription }
    }
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
        connectMonitorControls()
        if !busy { Task { await monitorControls.refresh(ifStale: true) } }
    }
    func refresh(quietly: Bool = false) {
        // Quiet status sampling must not queue another full DDC scan in a key burst.
        if quietly && monitorControls.working { return }
        if transition.phase == "unavailable", sessionAllowsControl {
            coordinator.setAvailability(nil)
        }
        coordinator.refresh(configuration: configuration, quietly: quietly)
    }
    private var idleTimer: Timer?
    private var sleepTimestamp: TimeInterval = 0

    var isPoweredOn: Bool {
        if isDisplaySleeping { return false }
        return status?.isPoweredOn ?? true
    }

    func setPower(_ on: Bool) {
        guard configured else { return }
        if on {
            stopIdleWatcher()
            Task {
                do {
                    try await coordinator.setPower(true, configuration: configuration)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } else {
            sleepTimestamp = ProcessInfo.processInfo.systemUptime
            startIdleWatcher()
            Task {
                do {
                    try await coordinator.setPower(false, configuration: configuration)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func startIdleWatcher() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPoweredOn else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.sleepTimestamp > 1.5 else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
                if idle < 0.25 {
                    self.setPower(true)
                }
            }
        }
    }

    private func stopIdleWatcher() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func togglePower() {
        setPower(!isPoweredOn)
    }
    func previous() {
        guard let preset = previousPreset else { return }
        apply(preset)
    }
    func refreshMonitorHDR() {
        guard !monitorHDR.busy else { return }
        let id = monitors.first { $0.serial == configuration.monitorSerial }?.displayID
        monitorHDR.refresh(displayID: id)
        monitorControls.updateHDR(monitorHDR.supported ? monitorHDR.enabled : nil)
    }
    func setHDR(_ enabled: Bool) {
        let serial = configuration.monitorSerial
        monitorControls.enqueueHDR(enabled) { [weak self] in
            guard let self, self.configuration.monitorSerial == serial else { return }
            await self.monitorHDR.setEnabled(enabled) { desired in try await self.engine.prepareHDR(desired, serial: serial) }
            self.refreshMonitorHDR()
            await self.monitorControls.refresh()
        }
    }
    func connectMonitorControls() {
        monitorControls.connect(serial: configuration.monitorSerial, engine: engine, displayID: monitors.first { $0.serial == configuration.monitorSerial }?.displayID)
        monitorControls.refreshHDR = { [weak self] in self?.refreshMonitorHDR() }
        refreshMonitorHDR()
        monitorControls.acceptsChanges = { [weak self] in
            guard let self else { return false }
            return self.configured && self.sessionAllowsControl && self.isPoweredOn
        }
        monitorControls.allowsControl = { [weak self] in
            guard let self else { return false }
            return self.configured && !self.busy && !self.monitorHDR.busy && !self.monitorControls.suspended && self.sessionAllowsControl && self.isPoweredOn
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
    func reorderPresets(_ orderedIDs: [UUID]) {
        guard !busy, orderedIDs.count == configuration.presets.count,
              Set(orderedIDs) == Set(configuration.presets.map(\.id)) else { return }
        let byID = Dictionary(uniqueKeysWithValues: configuration.presets.map { ($0.id, $0) })
        configuration.presets = orderedIDs.compactMap { byID[$0] }
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
