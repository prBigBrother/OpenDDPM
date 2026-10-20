import SwiftUI

// Use the property-wrapper type explicitly. New SDKs also introduce a State
// macro whose plugin is absent from standalone Command Line Tools installations.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let accent = Color(red: 0.22, green: 0.84, blue: 0.91)
private let violet = Color(red: 0.62, green: 0.53, blue: 0.99)

struct LayoutPreview: View {
    var preset: DisplayPreset
    var compact = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if preset.layout == .full || preset.layout.isPIP {
                    pane(preset.main.short, color: accent)
                    if preset.layout.isPIP {
                        pane(preset.secondary.short, color: violet)
                            .frame(width: geometry.size.width * (preset.layout == .pipSmall ? 0.3 : 0.43), height: geometry.size.height * 0.5)
                            .padding(8)
                    }
                } else {
                    HStack(spacing: 4) {
                        pane(preset.main.short, color: accent).frame(width: (geometry.size.width - 4) * preset.layout.fraction)
                        pane(preset.secondary.short, color: violet)
                    }
                }
            }
        }
        .padding(5)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.15)))
        .frame(height: compact ? 50 : 125)
        .accessibilityLabel(preset.detail)
    }
    private func pane(_ title: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.19))
            .overlay(Text(title).font(compact ? .caption.bold() : .title2.bold()).foregroundStyle(color))
    }
}

struct ConfigurationView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let image = NSImage(named: "AppIcon") { Image(nsImage: image).resizable().frame(width: 40, height: 40) }
                    VStack(alignment: .leading, spacing: 2) { Text("OpenDDPM").font(.title3.bold()); Text("Your screen. Your way.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.bottom, 30).padding(.top, 8)
                navigation("setup", "Monitor & inputs", "display")
                navigation("presets", "Presets", "rectangle.split.2x1")
                navigation("hotkeys", "Hotkeys", "command")
                navigation("automation", "Apple Home & Shortcuts", "house")
                navigation("about", "About OpenDDPM", "info.circle")
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label(store.configured ? store.configuration.monitorName : "Setup required", systemImage: store.configured ? "checkmark.circle.fill" : "circle.dashed").font(.caption.bold()).foregroundStyle(accent)
                    Text(store.configured ? "This Mac · \(store.configuration.localInput.title)" : "Identify your Mac’s cable to begin.").font(.caption).foregroundStyle(.secondary)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")").font(.caption2).foregroundStyle(.tertiary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }.padding(20).frame(width: 230).background(Color(red: 0.065, green: 0.08, blue: 0.12))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if store.selectedPage == "setup" { SetupView(store: store) }
                        else if store.selectedPage == "presets" { PresetsView(store: store) }
                        else if store.selectedPage == "hotkeys" { HotkeysView(store: store) }
                        else if store.selectedPage == "automation" { AutomationSettingsView(store: store, homekit: store.homekit) }
                        else { AboutView(store: store) }
                    }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 10) {
                    if store.busy { ProgressView().controlSize(.small) } else { Image(systemName: "display").foregroundStyle(accent) }
                    Text(store.progress).font(.caption).lineLimit(2)
                    Spacer()
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(store.busy)
                }.padding(14)
            }.frame(maxWidth: .infinity).background(Color(red: 0.09, green: 0.105, blue: 0.15))
        }.frame(minWidth: 920, minHeight: 650)
        .tint(accent)
        .alert("OpenDDPM", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func navigation(_ page: String, _ title: String, _ icon: String) -> some View {
        Button { store.selectedPage = page } label: {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(store.selectedPage == page ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(store.selectedPage == page ? accent : Color.secondary)
        }.buttonStyle(.plain).accessibilityIdentifier("nav-\(page)")
    }
}

private struct SetupView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        title("Make it yours", subtitle: "Connect a monitor, then tell OpenDDPM which input belongs to this Mac.")
        section("1", "Choose your monitor") {
            HStack {
                if store.monitors.isEmpty { Text("No monitors discovered yet").foregroundStyle(.secondary) }
                else {
                    Picker("Monitor", selection: Binding(get: { store.configuration.monitorSerial }, set: { store.selectMonitor($0) })) {
                        ForEach(store.monitors) { monitor in Text("\(monitor.name) · \(monitor.serial)").tag(monitor.serial) }
                    }.labelsHidden().frame(maxWidth: 390)
                }
                Spacer()
                Button("Discover") { store.refresh() }.disabled(store.busy).accessibilityIdentifier("discover")
            }
            if let status = store.status { Text("Now showing: \(status.description)").font(.caption).foregroundStyle(.secondary) }
            Text("Designed and tested for Dell U4025QW. DDC/CI must be enabled in the monitor’s on-screen menu.").font(.caption).foregroundStyle(.secondary)
        }
        section("2", "Identify this Mac’s input") {
            HStack(spacing: 10) {
                ForEach(VideoInput.allCases) { input in
                    Button { store.configuration.localInput = input; store.configuration.inputConfirmed = false } label: {
                        VStack(spacing: 8) {
                            Image(systemName: input == .thunderbolt ? "bolt.fill" : "cable.connector").font(.title2)
                            Text(input.title).font(.system(size: 12, weight: .semibold))
                            Text(input == store.status?.localInput ? "Detected connection" : "Select cable").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(store.configuration.localInput == input ? accent.opacity(0.14) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.configuration.localInput == input ? accent : Color.white.opacity(0.08)))
                    }.buttonStyle(.plain).accessibilityIdentifier("input-\(input.rawValue)")
                }
            }
            Text("Follow the cable from this Mac to the monitor. Detection is a suggestion; confirm the physical input. This step never switches your display.").font(.caption).foregroundStyle(.secondary)
            Toggle("Keep this Mac visible", isOn: $store.configuration.keepLocalVisible)
            Text("When enabled, presets that exclude \(store.configuration.localInput.title) are blocked. Turn it off only when you intend to hide this Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.configuration.inputConfirmed { Label("Input confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(accent) }
                Spacer()
                Button("Confirm input & view presets") { store.confirmInput() }.buttonStyle(.borderedProminent).disabled(store.configuration.monitorSerial.isEmpty || store.busy).accessibilityIdentifier("confirm-input")
            }
        }.disabled(store.busy)
    }
}

private struct PresetsView: View {
    @ObservedObject var store: AppStore
    @ViewState private var editing: DisplayPreset?
    var body: some View {
        HStack {
            title("One click. New workspace.", subtitle: "Create layouts for the way you move between machines.")
            Spacer()
            Button { editing = DisplayPreset(name: "New preset", layout: .equal, main: store.configuration.localInput, secondary: store.configuration.localInput == .dp ? .thunderbolt : .dp) } label: { Label("New preset", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(store.busy).accessibilityIdentifier("new-preset")
        }
        if !store.configured { Label("Complete monitor and input setup before applying presets.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(store.configuration.presets) { preset in
                let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                VStack(alignment: .leading, spacing: 12) {
                    LayoutPreview(preset: preset, compact: true)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name).font(.headline)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit preset") { editing = preset }
                            Button("Move earlier") { store.movePreset(preset.id, by: -1) }
                            Button("Move later") { store.movePreset(preset.id, by: 1) }
                            Divider()
                            Button("Delete preset", role: .destructive) { store.deletePreset(preset.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.busy)
                    }
                    HStack {
                        if blocked { Label("Hides this Mac", systemImage: "eye.slash").font(.caption2).foregroundStyle(.secondary) }
                        else if store.lastPresetID == preset.id { Label("Verified", systemImage: "checkmark").font(.caption2).foregroundStyle(accent) }
                        Spacer()
                        Button(store.transition.desiredPresetID == preset.id && store.busy ? "Selected" : "Apply") { store.apply(preset) }.disabled(blocked || !store.configured)
                    }
                }.padding(15).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.07)))
            }
        }
        HStack {
            Button("Import presets…") { store.importConfiguration() }
            Button("Export presets…") { store.exportConfiguration() }
            Spacer()
            Text("Saved automatically on this Mac").font(.caption).foregroundStyle(.secondary)
        }.disabled(store.busy)
        .sheet(item: $editing) { preset in PresetEditor(preset: preset) { store.savePreset($0); editing = nil } cancel: { editing = nil } }
    }
}

private struct PresetEditor: View {
    @ViewState var preset: DisplayPreset
    var save: (DisplayPreset) -> Void
    var cancel: () -> Void
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Design a preset").font(.title2.bold())
            LayoutPreview(preset: preset)
            TextField("Preset name", text: $preset.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-name")
            Picker("Layout", selection: $preset.layout) { ForEach(SplitLayout.allCases) { Text($0.title).tag($0) } }
            Picker(preset.layout.isPIP ? "Main input" : "Left / main input", selection: $preset.main) { ForEach(VideoInput.allCases) { Text($0.title).tag($0) } }
            if preset.layout != .full { Picker(preset.layout.isPIP ? "Inset input" : "Right / secondary input", selection: $preset.secondary) { ForEach(VideoInput.allCases) { Text($0.title).tag($0) } } }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save preset") { do { try preset.validate(); save(preset) } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("save-preset")
            }
        }.padding(28).frame(width: 470).tint(accent)
    }
}

private struct HotkeysView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        title("Your workspace, at a keystroke.", subtitle: "Bind a global shortcut to any preset. It works while another app is focused.")
        HStack {
            Text("Open preset remote").font(.headline)
            Spacer()
            ShortcutRecorder(preset: DisplayPreset(id: AppStore.remoteID, name: "Preset remote", layout: .full, main: .dp, secondary: .hdmi, shortcut: store.configuration.effectiveRemoteShortcut), capture: { store.setRemoteShortcut($0) }, recordingChanged: { store.shortcutRecording($0) }).frame(width: 145, height: 28)
            Button("Default") { store.setRemoteShortcut(PresetShortcut(keyCode: 49, modifiers: PresetShortcut.control | PresetShortcut.option, keyLabel: "Space")) }
        }
        if let issue = store.hotkeyIssues[AppStore.remoteID] { Text(issue).foregroundStyle(.orange) }
        Text("Click Record, then press a key with Control, Option, or Command. Escape cancels.").font(.callout).foregroundStyle(.secondary)
        VStack(spacing: 0) {
            ForEach(store.configuration.presets) { preset in
                let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.name).font(.headline)
                        Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        if let issue = store.hotkeyIssues[preset.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                        else if blocked { Text("Inactive: this preset hides this Mac").font(.caption).foregroundStyle(.secondary) }
                        else if !store.configured { Text("Complete monitor setup to activate").font(.caption).foregroundStyle(.secondary) }
                        else if preset.shortcut != nil { Text("Active globally").font(.caption).foregroundStyle(accent) }
                    }
                    Spacer()
                    ShortcutRecorder(preset: preset, capture: { store.setShortcut($0, for: preset.id) }, recordingChanged: { store.shortcutRecording($0) }).frame(width: 145, height: 28)
                    Button { store.setShortcut(nil, for: preset.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).disabled(preset.shortcut == nil).help("Clear this hotkey")
                }.padding(18)
                if preset.id != store.configuration.presets.last?.id { Divider().padding(.horizontal, 18) }
            }
        }.background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.07))).disabled(store.busy)
        Label("No Accessibility or Input Monitoring permission is needed.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
    }
}

private struct AboutView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        title("OpenDDPM", subtitle: "A small, open-source menu bar companion for your ultrawide workspace.")
        section("", "Built to stay out of the way") {
            Text("Pick a preset from the menu bar, or create one here. Layout changes use the monitor’s own Picture-by-Picture and Picture-in-Picture controls.").foregroundStyle(.secondary)
            Toggle("Launch OpenDDPM at login", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
        }
        section("", "Built-in monitor control") {
            Label("Standalone native DDC/CI driver", systemImage: "cable.connector").foregroundStyle(accent)
            Text("OpenDDPM communicates directly with the monitor using macOS IOKit. No external monitor-control application, CLI installation, Python, or Homebrew is required.").font(.callout).foregroundStyle(.secondary)
            Text("Apple Silicon uses IOAVService; Intel uses the I2C framebuffer interface. Enable DDC/CI in the monitor’s own menu.").font(.caption).foregroundStyle(.secondary)
            Text("Universal app for Apple Silicon and Intel · macOS 13 or newer").font(.caption).foregroundStyle(.secondary)
        }
        section("", "Open source") {
            HStack {
                Link("GitHub repository ↗", destination: URL(string: "https://github.com/prBigBrother/OpenDDPM")!)
                Link("Download releases ↗", destination: URL(string: "https://github.com/prBigBrother/OpenDDPM/releases")!)
            }
            Text("Independent software. Not affiliated with Dell. Monitor support is currently validated on the U4025QW.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func title(_ text: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) { Text(text).font(.system(size: 27, weight: .bold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
}

private func section<Content: View>(_ number: String, _ heading: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 15) {
        HStack(spacing: 10) {
            if !number.isEmpty { Text(number).font(.caption.bold()).frame(width: 23, height: 23).background(accent.opacity(0.16), in: Circle()).foregroundStyle(accent) }
            Text(heading).font(.headline)
        }
        content()
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.07)))
}
