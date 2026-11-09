import AppKit
import CoreGraphics
import SwiftUI

struct MonitorDisplayMode: Identifiable {
    let native: CGDisplayMode
    var id: Int32 { native.ioDisplayModeID }
    var width: Int { native.width }
    var height: Int { native.height }
    var hiDPI: Bool { native.pixelWidth > native.width || native.pixelHeight > native.height }
    var refreshRate: Double { native.refreshRate }
    var resolution: String { "\(width) × \(height)" }
    var rateTitle: String {
        refreshRate > 0 ? String(format: "%.2f Hz", refreshRate) : "Default"
    }
}

/// Uses only the display ID supplied by native discovery for the selected serial.
/// Mode changes are temporary until explicitly confirmed and revert after 15 seconds.
@MainActor
final class MonitorDisplayModes: ObservableObject {
    @Published private(set) var modes: [MonitorDisplayMode] = []
    @Published private(set) var current: MonitorDisplayMode?
    @Published private(set) var awaitingConfirmation = false
    @Published var error: String?
    private var displayID: CGDirectDisplayID?
    private var originalMode: CGDisplayMode?
    private var revertTask: Task<Void, Never>?

    func refresh(displayID: CGDirectDisplayID?) {
        if self.displayID != displayID, awaitingConfirmation { revert() }
        self.displayID = displayID
        guard let displayID, CGDisplayIsOnline(displayID) != 0 else {
            modes = []; current = nil
            return
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let available = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        // Keep one ID per logical size/rate/scale. Duplicate framebuffer formats
        // must not produce visually identical entries in the controls.
        var seen = Set<String>()
        modes = available.map { MonitorDisplayMode(native: $0) }.filter { mode in
            guard mode.width > 0, mode.height > 0 else { return false }
            let key = "\(mode.width):\(mode.height):\(mode.hiDPI):\(Int((mode.refreshRate * 100).rounded()))"
            return seen.insert(key).inserted
        }.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.refreshRate > $1.refreshRate
        }
        current = CGDisplayCopyDisplayMode(displayID).map { MonitorDisplayMode(native: $0) }
    }

    var resolutions: [String] {
        guard let current else { return [] }
        var seen = Set<String>()
        return modes.filter { $0.hiDPI == current.hiDPI }.map(\.resolution).filter { seen.insert($0).inserted }
    }
    var refreshRates: [MonitorDisplayMode] {
        guard let current else { return [] }
        return modes.filter { $0.width == current.width && $0.height == current.height && $0.hiDPI == current.hiDPI }
    }
    var canToggleHiDPI: Bool {
        guard let current else { return false }
        return modes.contains { $0.width == current.width && $0.height == current.height && $0.hiDPI != current.hiDPI }
    }

    func setResolution(_ resolution: String) {
        guard let current else { return }
        let candidates = modes.filter { $0.resolution == resolution && $0.hiDPI == current.hiDPI }
        choose(candidates.min { abs($0.refreshRate - current.refreshRate) < abs($1.refreshRate - current.refreshRate) })
    }
    func setRefreshRate(_ modeID: Int32) {
        guard let mode = refreshRates.first(where: { $0.id == modeID }) else { return }
        choose(mode)
    }
    func setHiDPI(_ enabled: Bool) {
        guard let current else { return }
        let candidates = modes.filter { $0.width == current.width && $0.height == current.height && $0.hiDPI == enabled }
        choose(candidates.min { abs($0.refreshRate - current.refreshRate) < abs($1.refreshRate - current.refreshRate) })
    }
    private func choose(_ mode: MonitorDisplayMode?) {
        guard let mode, let displayID, CGDisplayIsOnline(displayID) != 0 else {
            error = "This combination is unavailable. Choose another resolution or refresh rate."
            return
        }
        guard !awaitingConfirmation else { return }
        guard let before = CGDisplayCopyDisplayMode(displayID) else {
            error = "The selected monitor is reconnecting. Refresh its display modes."
            return
        }
        let result = CGDisplaySetDisplayMode(displayID, mode.native, nil)
        guard result == .success else {
            error = "macOS could not apply the display mode (\(result.rawValue))."
            return
        }
        originalMode = before
        awaitingConfirmation = true
        refresh(displayID: displayID)
        guard let actual = current, actual.width == mode.width, actual.height == mode.height, actual.hiDPI == mode.hiDPI, abs(actual.refreshRate - mode.refreshRate) < 0.1 else {
            error = "macOS did not confirm the requested mode. Restoring the previous settings."
            revert()
            return
        }
        revertTask?.cancel()
        revertTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            self?.revert()
        }
    }
    func keep() {
        revertTask?.cancel(); revertTask = nil
        originalMode = nil; awaitingConfirmation = false
    }
    func revert() {
        revertTask?.cancel(); revertTask = nil
        if let displayID, let originalMode {
            let result = CGDisplaySetDisplayMode(displayID, originalMode, nil)
            if result != .success { error = "macOS could not restore the previous mode (\(result.rawValue)). Open System Settings → Displays." }
        }
        originalMode = nil; awaitingConfirmation = false
        refresh(displayID: displayID)
    }
}

struct MonitorDisplayModesView: View {
    @ObservedObject var controller: MonitorDisplayModes
    var displayID: CGDirectDisplayID?

    var body: some View {
        Section("Resolution & frame rate") {
            if let current = controller.current {
                Picker("Resolution", selection: Binding(get: { controller.current?.resolution ?? current.resolution }, set: { controller.setResolution($0) })) {
                    ForEach(controller.resolutions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Refresh rate", selection: Binding(get: {
                    controller.refreshRates.first { abs($0.refreshRate - (controller.current?.refreshRate ?? 0)) < 0.01 }?.id ?? current.id
                }, set: { controller.setRefreshRate($0) })) {
                    ForEach(controller.refreshRates) { Text($0.rateTitle).tag($0.id) }
                }
                Toggle("HiDPI", isOn: Binding(get: { controller.current?.hiDPI ?? false }, set: { controller.setHiDPI($0) }))
                    .disabled(!controller.canToggleHiDPI)
                if !controller.canToggleHiDPI {
                    Text("macOS does not expose both scale modes at this resolution.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Display modes are unavailable for the selected monitor. Refresh monitor discovery.").foregroundStyle(.secondary)
            }
            if let error = controller.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .disabled(controller.awaitingConfirmation)
        .onAppear { controller.refresh(displayID: displayID) }
        .onChange(of: displayID) { controller.refresh(displayID: $0) }
        .onDisappear { if controller.awaitingConfirmation { controller.revert() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            controller.refresh(displayID: displayID)
        }
        if controller.awaitingConfirmation {
            Section {
                Text("Keep these display settings? Reverting automatically after 15 seconds.")
                HStack {
                    Button("Revert") { controller.revert() }
                    Button("Keep") { controller.keep() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
