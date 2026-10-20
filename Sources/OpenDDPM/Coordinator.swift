import Foundation

struct TransitionState: Codable {
    var phase = "idle"
    var desiredPresetID: UUID?
    var verifiedPresetID: UUID?
    var previousPresetID: UUID?
    var requestID: UUID?
    var monitor: MonitorStatus?
    var observedAt: Date?
    var progress = "Ready"
    var error: String?
    var elapsed: Double?
}

struct RequestReceipt: Codable {
    var id: UUID
    var presetID: UUID
    var phase: String
    var error: String?
}

@MainActor
final class PresetCoordinator {
    private struct Request {
        var id: UUID
        var preset: DisplayPreset
        var configuration: AppConfiguration
    }
    let engine: any MonitorControlling
    let journal: TransitionJournal
    private(set) var state = TransitionState()
    private(set) var monitors: [ConnectedMonitor] = []
    private(set) var receipts: [RequestReceipt] = []
    private var desired: Request?
    private var refreshConfiguration: (configuration: AppConfiguration, quiet: Bool)?
    private var readingInBackground = false
    private var worker: Task<Void, Never>?
    private var unavailableReason: String?
    var onChange: (() -> Void)?
    var busy: Bool { desired != nil || (worker != nil && !readingInBackground) }
    init(engine: any MonitorControlling, journal: TransitionJournal = .standard) { self.engine = engine; self.journal = journal }
    @discardableResult
    func submit(_ preset: DisplayPreset, configuration: AppConfiguration) throws -> UUID {
        if let reason = unavailableReason { throw ControlError.message(reason) }
        try configuration.validate(); try preset.validate()
        guard configuration.inputConfirmed, !configuration.monitorSerial.isEmpty else { throw ControlError.message("Complete monitor setup first.") }
        guard !configuration.keepLocalVisible || preset.includes(configuration.localInput) else { throw ControlError.message("This preset hides this Mac's \(configuration.localInput.title) input.") }
        if let desired, desired.preset == preset { return desired.id }
        if let pending = desired { finish(pending.id, phase: "superseded") }
        let request = Request(id: UUID(), preset: preset, configuration: configuration)
        desired = request
        receipts.append(RequestReceipt(id: request.id, presetID: preset.id, phase: "queued"))
        if receipts.count > 100 { receipts.removeFirst(receipts.count - 100) }
        state.requestID = request.id; state.desiredPresetID = preset.id; state.phase = "queued"
        state.progress = "Selected \(preset.name)"; state.error = nil; state.elapsed = nil
        journal.record("selected", request: request.id, fields: ["preset": preset.name, "presetID": preset.id.uuidString])
        startWorker(); onChange?()
        return request.id
    }
    func refresh(configuration: AppConfiguration, quietly: Bool = false) {
        guard unavailableReason == nil else { return }
        refreshConfiguration = (configuration, quietly)
        if worker == nil { readingInBackground = quietly }
        startWorker(); onChange?()
    }
    func setAvailability(_ reason: String?) {
        unavailableReason = reason
        if let reason {
            if let request = desired {
                finish(request.id, phase: "failed", error: reason)
                journal.record("interrupted", request: request.id, fields: ["reason": reason])
            }
            desired = nil; refreshConfiguration = nil
            state.phase = "unavailable"; state.error = reason; state.observedAt = nil
            state.progress = reason
        }
        onChange?()
    }
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }
    private func finish(_ id: UUID, phase: String, error: String? = nil) {
        if let index = receipts.firstIndex(where: { $0.id == id }), ["queued", "applying"].contains(receipts[index].phase) {
            receipts[index].phase = phase; receipts[index].error = error
            if phase != "applying" { journal.record("request-" + phase, request: id, fields: ["error": error ?? ""]) }
        }
    }
    private func confirm(_ status: MonitorStatus, configuration: AppConfiguration) {
        let current = configuration.presets.first { $0.id == state.verifiedPresetID && status.matches($0) }
        let match = current?.id ?? configuration.presets.first(where: { status.matches($0) })?.id
        if let old = state.verifiedPresetID, old != match { state.previousPresetID = old }
        state.verifiedPresetID = match
        state.monitor = status; state.observedAt = Date()
    }
    private func drain() async {
        while desired != nil || refreshConfiguration != nil {
            if let request = desired {
                readingInBackground = false
                let start = ProcessInfo.processInfo.systemUptime
                state.phase = "applying"; state.error = nil; state.observedAt = nil
                finish(request.id, phase: "applying"); onChange?()
                do {
                    let result = try await engine.apply(request.preset, configuration: request.configuration, request: request.id,
                        isCurrent: { [weak self] in await self?.isCurrent(request.id) ?? false },
                        progress: { [weak self] text in await self?.report(text, request: request.id) })
                    guard isCurrent(request.id) else { finish(request.id, phase: "superseded"); continue }
                    switch result {
                    case .verified(let status):
                        if let old = state.verifiedPresetID, old != request.preset.id { state.previousPresetID = old }
                        state.monitor = status; state.observedAt = Date()
                        state.verifiedPresetID = request.preset.id
                        state.phase = "verified"; state.progress = "\(request.preset.name) · verified"
                    case .unverified:
                        if let old = state.verifiedPresetID { state.previousPresetID = old }
                        state.monitor = nil; state.observedAt = nil; state.verifiedPresetID = nil
                        state.phase = "unverified"; state.progress = "Sent \(request.preset.name) · this Mac is hidden; readback unavailable"
                    case .superseded:
                        state.phase = "superseded"; state.progress = "Selection changed"
                    }
                    finish(request.id, phase: state.phase)
                } catch {
                    guard isCurrent(request.id) else { finish(request.id, phase: "superseded"); continue }
                    state.phase = "failed"; state.error = error.localizedDescription
                    state.progress = "Preset not verified · retry verification or select a preset"
                    state.observedAt = nil
                    finish(request.id, phase: "failed", error: error.localizedDescription)
                }
                state.elapsed = ProcessInfo.processInfo.systemUptime - start
                journal.record(state.phase, request: request.id, fields: ["ms": Int((state.elapsed ?? 0) * 1000), "error": state.error ?? ""])
                desired = nil; onChange?()
            } else if let refresh = refreshConfiguration {
                let configuration = refresh.configuration
                refreshConfiguration = nil
                readingInBackground = refresh.quiet
                if !refresh.quiet { state.phase = "refreshing"; state.progress = "Reading monitor state" }
                onChange?()
                do {
                    monitors = try await engine.discover()
                    var selected = configuration
                    if selected.monitorSerial.isEmpty, let first = monitors.first(where: { $0.name.contains("U4025QW") }) { selected.monitorSerial = first.serial }
                    guard !selected.monitorSerial.isEmpty else { throw ControlError.message("No U4025QW found. Connect the monitor and enable DDC/CI.") }
                    let status = try await engine.status(serial: selected.monitorSerial)
                    guard unavailableReason == nil else { continue }
                    // Never overwrite a newer selection's progress with a refresh result.
                    confirm(status, configuration: selected)
                    if desired == nil { state.phase = "verified"; state.progress = status.description; state.error = nil; state.requestID = nil; state.elapsed = nil }
                } catch {
                    if desired == nil && unavailableReason == nil { state.phase = "failed"; state.progress = "Monitor unavailable"; state.error = error.localizedDescription; state.observedAt = nil }
                }
                onChange?()
            }
        }
        readingInBackground = false; worker = nil; onChange?()
    }
    private func isCurrent(_ id: UUID) -> Bool { desired?.id == id }
    private func report(_ text: String, request: UUID) {
        guard isCurrent(request) else { return }
        state.progress = text; onChange?()
    }
}
