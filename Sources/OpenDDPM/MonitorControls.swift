import SwiftUI
import Combine
import QuartzCore

struct MonitorSlider: View {
    @ObservedObject var controls: MonitorControls
    var feature: PictureFeature
    var disabled = false
    @ViewState private var draft = 0.0
    @ViewState private var editing = false
    private var reportedValue: Double? { feature.register == 0x10 ? controls.displayedBrightness : controls.displayedValue(for: feature).map(Double.init) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(feature.title)
                Spacer()
                Text(editing ? "\(Int(draft.rounded()))%" : reportedValue.map { "\(Int($0.rounded()))%" } ?? "Unavailable")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { draft }, set: { value in
                draft = value
                controls.set(feature, to: Int(value.rounded()))
            }), in: 0...100, onEditingChanged: { editing = $0 })
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel(feature.title)
            .disabled(disabled || reportedValue == nil || (feature.register == 0x10 && !controls.canAdjustBrightness))
            .help((feature.register == 0x10 ? controls.brightnessLockReason : nil) ?? controls.failures[feature.register] ?? feature.title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = reportedValue ?? 0 }
        .onChange(of: reportedValue) { value in
            if !editing { withAnimation(.easeOut(duration: 0.14)) { draft = value ?? 0 } }
        }
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controls: MonitorControls
    @StateObject private var displayModes = MonitorDisplayModes()
    @ObservedObject var hdr: MonitorHDR
    init(store: AppStore, controls: MonitorControls) {
        self.store = store; self.controls = controls; self.hdr = store.monitorHDR
    }
    private var displayID: UInt32? { store.monitors.first { $0.serial == store.configuration.monitorSerial }?.displayID }
    var body: some View {
        Form {
            Section("Brightness & contrast") {
                MonitorSlider(controls: controls, feature: .brightness)
                if let reason = controls.brightnessLockReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                Toggle("Automatic brightness", isOn: Binding(get: { controls.autoBrightness }, set: { controls.setAutoBrightness($0) }))
                    .disabled(controls.displayedValue(for: .automatic) == nil)
                Picker("Auto Brightness Range Level", selection: Binding(get: { (controls.displayedValue(for: .automatic) ?? 0) >> 6 & 3 }, set: { controls.setAutoRange($0) })) {
                    Text("Low").tag(0); Text("Medium").tag(1); Text("High").tag(2)
                }.disabled(controls.displayedValue(for: .automatic) == nil || !controls.autoBrightness)
                MonitorSlider(controls: controls, feature: .contrast)
            }
            Section("HDR") {
                Toggle("HDR", isOn: Binding(get: { controls.hdrPreview ?? hdr.enabled }, set: { store.setHDR($0) }))
                .disabled(!hdr.supported)
                if hdr.enabled {
                    Text("HDR is on. Available brightness controls depend on the monitor and connection.").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = hdr.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if let error = hdr.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Color") {
                Picker("Color preset", selection: Binding(get: { controls.displayedValue(for: .color) ?? -1 }, set: { controls.set(.color, to: $0) })) {
                    Text("Unavailable").tag(-1)
                    ForEach(PictureFeature.color.choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
                }
                if controls.values[PictureFeature.color.register] == nil {
                    Text("The current color preset is unavailable. You can select a preset; OpenDDPM checks the monitor response after applying it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            MonitorDisplayModesView(controller: displayModes, displayID: store.monitors.first { $0.serial == store.configuration.monitorSerial }?.displayID)
            BrightnessKeysSettingsView(controller: store.brightnessKeys, osd: store.brightnessOSD)
            Section("Audio") { MonitorSlider(controls: controls, feature: .volume) }
            if let message = controls.message { Section { StatusBanner(message: message, isError: true) } }
            Section {
                Button("Refresh monitor settings") { Task { await controls.refresh() } }
                    .disabled(!store.configured)
                Text("Settings are read from the selected monitor. Unavailable controls may be restricted by HDR, a split layout, or the current connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.configured)
        .onChange(of: displayID) { _ in store.refreshMonitorHDR() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in store.refreshMonitorHDR() }
        .task(id: controls.nativeObservationIdentity) {
            store.connectMonitorControls()
            store.refreshMonitorHDR()
            await controls.refresh()
            await controls.observeNativeBrightness()
        }
    }
}

private struct QuickSliderRow: View {
    @ObservedObject var controls: MonitorControls
    let feature: PictureFeature
    let lowIcon: String
    let highIcon: String
    @ViewState private var draft = 0.0
    @ViewState private var editing = false
    private var reportedValue: Double? { feature.register == 0x10 ? controls.displayedBrightness : controls.displayedValue(for: feature).map(Double.init) }
    private var lock: String? { feature.register == 0x10 ? controls.brightnessLockReason : nil }
    private var enabled: Bool { lock == nil && reportedValue != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(feature.title).font(.headline)
                Spacer()
                Text(lock == nil ? (reportedValue.map { "\(Int($0.rounded()))%" } ?? "Unavailable") : (controls.hdrEnabled == true ? "HDR on" : controls.autoBrightness ? "Auto" : "Checking…"))
                    .foregroundStyle(.secondary).font(.callout).monospacedDigit()
            }
            HStack(spacing: 8) {
                Image(systemName: lowIcon).frame(width: 18)
                Slider(value: Binding(get: { draft }, set: { value in
                    draft = value
                    controls.set(feature, to: Int(value.rounded()))
                }), in: 0...100, onEditingChanged: { editing = $0 })
                .labelsHidden()
                .accessibilityLabel(feature.title)
                .disabled(!enabled)
                .frame(height: 22)
                Image(systemName: highIcon).frame(width: 22)
            }
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .help(lock ?? controls.failures[feature.register] ?? feature.title)
        }
        .onAppear { draft = reportedValue ?? 0 }
        .onChange(of: reportedValue) { value in
            guard !editing, let value else { return }
            withAnimation(.easeOut(duration: 0.14)) { draft = value }
        }
    }
}

private struct QuickMenuRow: View {
    var title: String
    var icon: String?
    var checked = false
    var reserveSelectionSpace = true
    var enabled = true
    var action: () -> Void
    @ViewState private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if reserveSelectionSpace {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .opacity(checked ? 1 : 0).frame(width: 14)
                }
                if let icon { Image(systemName: icon).frame(width: 20) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovered && enabled ? Color.primary.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel(title + (checked ? ", selected" : ""))
    }
}

struct QuickMonitorView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controls: MonitorControls
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.configuration.monitorName).font(.headline)
                QuickSliderRow(controls: controls, feature: .brightness, lowIcon: "sun.min.fill", highIcon: "sun.max.fill")
                QuickSliderRow(controls: controls, feature: .volume, lowIcon: "speaker.fill", highIcon: "speaker.wave.3.fill")
            }.padding(14)
            Divider().padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 0) {
                Text("Presets").font(.headline).padding(.horizontal, 10).padding(.top, 11).padding(.bottom, 5)
                ForEach(Array(store.configuration.presets.prefix(4))) { preset in
                    QuickMenuRow(title: preset.name, icon: preset.layout == .full ? "display" : "rectangle.split.2x1", checked: store.lastPresetID == preset.id,
                                 enabled: store.configured && (!store.configuration.keepLocalVisible || preset.includes(store.configuration.localInput))) { store.apply(preset) }
                }
            }.padding(.horizontal, 5).padding(.bottom, 7)
            Divider().padding(.horizontal, 10)
            VStack(spacing: 0) {
                QuickMenuRow(title: "All presets…", icon: nil, reserveSelectionSpace: false) {
                    store.selectedPage = "presets"
                    store.openWindow?()
                }
                QuickMenuRow(title: "Settings…", icon: nil, reserveSelectionSpace: false) { store.openWindow?() }
                QuickMenuRow(title: "Quit OpenDDPM", icon: nil, reserveSelectionSpace: false, enabled: !store.busy) { store.quitApplication?() }
            }.padding(5)
            if let message = controls.message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 10) }
        }
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: controls.nativeObservationIdentity) {
            store.connectMonitorControls()
            await controls.refresh()
            await controls.observeNativeBrightness()
        }
    }
}

struct BrightnessKeysSettingsView: View {
    @ObservedObject var controller: BrightnessKeyController
    @ObservedObject var osd: BrightnessOSD
    var body: some View {
        Section("Keyboard brightness") {
            Toggle("Use native brightness keys for this monitor", isOn: Binding(get: { controller.requested }, set: { controller.setEnabled($0) }))
            Toggle("Use F1/F2 as brightness keys", isOn: Binding(get: { controller.functionKeysEnabled }, set: { controller.setFunctionKeysEnabled($0) }))
                .disabled(!controller.requested)
            Text("For keyboards that send F1/F2 instead of brightness commands. Applies to all keyboards; Command, Control and Option shortcuts remain available.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Brightness indicator", selection: Binding(get: { osd.style }, set: { osd.setStyle($0) })) {
                ForEach(BrightnessHUDStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(osd.style == .modern ? "OpenDDPM indicator with the current macOS appearance." : "Uses the classic macOS system indicator.")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.statusText).font(.caption).foregroundStyle(controller.isEnabled ? Color.secondary : Color.orange)
            Text("Requires Accessibility permission. Supports media brightness keys and legacy F14/F15 for the selected monitor. Option–Shift adjusts in smaller steps.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = controller.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let issue = osd.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
    }
}
