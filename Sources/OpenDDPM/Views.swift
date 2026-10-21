import SwiftUI

// Avoid the State macro supplied by newer SDKs when building with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

let accent = Color.accentColor
let violet = Color.purple
let warningColor = Color.orange
let errorColor = Color.red

struct IconButton: View {
    var icon: String
    var help: String
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(help, systemImage: icon)
        }
        .labelStyle(.iconOnly)
        .help(help)
    }
}

struct StatusBanner: View {
    var message: String
    var isError = false

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
            .font(.callout)
            .foregroundStyle(isError ? errorColor : warningColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "System"; case .light: return "Light"; case .dark: return "Dark" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
    var nsAppearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

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
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
        .frame(height: compact ? 50 : 125)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.detail)
    }
    private func pane(_ title: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.19))
            .overlay(Text(title).font(compact ? .caption.bold() : .title2.bold()).foregroundStyle(color))
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case setup, presets, hotkeys, automation, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: return "Monitor & inputs"
        case .presets: return "Presets"
        case .hotkeys: return "Hotkeys"
        case .automation: return "Apple Home"
        case .about: return "General & about"
        }
    }
    var icon: String {
        switch self {
        case .setup: return "display"
        case .presets: return "rectangle.split.2x1"
        case .hotkeys: return "command"
        case .automation: return "house"
        case .about: return "gearshape"
        }
    }
}

struct ConfigurationView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(get: { store.selectedPage }, set: {
                if let page = $0 { store.selectedPage = page }
            })) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.icon)
                        .tag(page.rawValue)
                        .accessibilityIdentifier("nav-\(page.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("OpenDDPM")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.configured ? store.configuration.monitorName : "Setup required")
                        .font(.caption.weight(.semibold))
                    Text(store.configured ? "This Mac · \(store.configuration.localInput.title)" : "Identify this Mac’s input to begin.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
        } detail: {
            Group {
                switch SettingsPage(rawValue: store.selectedPage) ?? .setup {
                case .setup: SetupView(store: store)
                case .presets: PresetsView(store: store)
                case .hotkeys: HotkeysView(store: store)
                case .automation: AutomationSettingsView(store: store, homekit: store.homekit)
                case .about: AboutView(store: store)
                }
            }
            .id(store.selectedPage)
            .navigationTitle((SettingsPage(rawValue: store.selectedPage) ?? .setup).title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.progress).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.bar)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { store.openRemote?() } label: {
                        Label("Open preset remote", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Open preset remote")
                    Button { store.refresh() } label: {
                        Label("Refresh monitor status", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.busy)
                    .help("Refresh monitor status")
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
        .onAppear { NSApp.appearance = AppAppearance(rawValue: appearanceRaw)?.nsAppearance }
        .onChange(of: appearanceRaw) { NSApp.appearance = AppAppearance(rawValue: $0)?.nsAppearance }
        .alert("OpenDDPM", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct SetupView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                if store.monitors.isEmpty {
                    LabeledContent("Monitor", value: "No monitors discovered")
                } else {
                    Picker("Monitor", selection: Binding(get: { store.configuration.monitorSerial }, set: { store.selectMonitor($0) })) {
                        ForEach(store.monitors) { Text("\($0.name) · \($0.serial)").tag($0.serial) }
                    }
                    .disabled(store.busy)
                }
                Button { store.refresh() } label: { Label("Discover monitors", systemImage: "arrow.clockwise") }
                    .disabled(store.busy)
                    .accessibilityIdentifier("discover")
                if let status = store.status {
                    LabeledContent("Now showing", value: status.description)
                }
            } header: {
                Text("Monitor")
            } footer: {
                Text("Designed and tested for Dell U4025QW. Enable DDC/CI in the monitor’s on-screen menu.")
            }
            Section {
                Picker("Connected input", selection: Binding(get: { store.configuration.localInput }, set: {
                    store.configuration.localInput = $0
                    store.configuration.inputConfirmed = false
                })) {
                    ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("local-input")
                if let detected = store.status?.localInput {
                    LabeledContent("Detected connection", value: detected.title)
                }
                if store.configuration.inputConfirmed {
                    Label("Input confirmed", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Button("Confirm input & view presets") { store.confirmInput() }
                    .disabled(store.configuration.monitorSerial.isEmpty)
                    .accessibilityIdentifier("confirm-input")
            } header: {
                Text("This Mac’s input")
            } footer: {
                Text("Follow the cable from this Mac to the monitor. Detection is a suggestion. Confirming the input does not switch your display.")
            }
            .disabled(store.busy)
            Section {
                Toggle("Keep this Mac visible", isOn: $store.configuration.keepLocalVisible)
            } footer: {
                Text("Blocks presets that exclude \(store.configuration.localInput.title). If turned off, a preset can hide this Mac and interrupt monitor control.")
            }
            .disabled(store.busy)
        }
        .formStyle(.grouped)
    }
}

private struct PresetsView: View {
    @ObservedObject var store: AppStore
    @ViewState private var editing: DisplayPreset?
    @ViewState private var shortcutPreset: DisplayPreset?

    private func newPreset() {
        editing = DisplayPreset(name: "New preset", layout: .equal, main: store.configuration.localInput,
                                secondary: store.configuration.localInput == .dp ? .thunderbolt : .dp)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.configured {
                HStack {
                    StatusBanner(message: "Complete monitor and input setup before applying presets.")
                    Spacer()
                    Button("Set up monitor") { store.selectedPage = "setup" }
                }.padding()
            }
            if store.busy {
                Text("Choose another preset at any time to change the target.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            if store.configuration.presets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No presets yet").font(.headline)
                    Text("Create a layout for your workspace.").foregroundStyle(.secondary)
                    Button("Create first preset", action: newPreset)
                        .disabled(store.busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.configuration.presets) { preset in
                        PresetRow(preset: preset, store: store,
                                  edit: { editing = preset }, shortcut: { shortcutPreset = preset })
                            .moveDisabled(store.busy)
                    }
                    .onMove { offsets, destination in
                        var ids = store.configuration.presets.map(\.id)
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        store.reorderPresets(ids)
                    }
                }
                .listStyle(.inset)
                Text("Drag presets to reorder. Changes are saved automatically.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: newPreset) { Label("New preset", systemImage: "plus") }
                    .disabled(store.busy).help("New preset").accessibilityIdentifier("new-preset")
                Menu {
                    Button("Import presets…") { store.importConfiguration() }
                    Button("Export presets…") { store.exportConfiguration() }
                } label: { Label("Preset actions", systemImage: "ellipsis.circle") }
                .disabled(store.busy).help("Import or export presets")
            }
        }
        .sheet(item: $shortcutPreset) { ShortcutSetupView(preset: $0) }
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { store.savePreset($0); editing = nil } cancel: { editing = nil }
        }
    }
}

private struct PresetRow: View {
    let preset: DisplayPreset
    @ObservedObject var store: AppStore
    let edit: () -> Void
    let shortcut: () -> Void

    private var hidesLocal: Bool { !preset.includes(store.configuration.localInput) }
    private var blocked: Bool { store.configuration.keepLocalVisible && hidesLocal }
    private var selected: Bool { store.busy && store.transition.desiredPresetID == preset.id }
    private var verified: Bool { !store.busy && store.lastPresetID == preset.id }

    var body: some View {
        HStack(spacing: 14) {
            LayoutPreview(preset: preset, compact: true).frame(width: 110)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(.headline)
                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                if blocked {
                    Label("Blocked · hides this Mac", systemImage: "lock").font(.caption).foregroundStyle(warningColor)
                } else if selected {
                    Label("Selected · applying", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                } else if verified {
                    Label("Verified", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(accent)
                } else if hidesLocal {
                    Label("Hides this Mac", systemImage: "eye.slash").font(.caption).foregroundStyle(warningColor)
                }
            }
            Spacer()
            Menu {
                Button("Edit preset", action: edit)
                Button("Set up Apple Shortcut…", action: shortcut)
                Divider()
                Button("Delete preset", role: .destructive) { store.deletePreset(preset.id) }
            } label: { Label("Options for \(preset.name)", systemImage: "ellipsis") }
            .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize()
            .disabled(store.busy)
            Button(verified ? "Applied" : selected ? "Applying…" : "Apply") { store.apply(preset) }
                .disabled(blocked || !store.configured)
                .accessibilityLabel("Apply \(preset.name)")
                .help(blocked ? "Blocked by Keep this Mac visible" : "Apply \(preset.name)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Edit preset", action: edit).disabled(store.busy)
            Button("Set up Apple Shortcut…", action: shortcut)
        }
    }
}

private struct PresetEditor: View {
    @ViewState var preset: DisplayPreset
    var save: (DisplayPreset) -> Void
    var cancel: () -> Void
    @ViewState private var error: String?

    private var hasConflict: Bool { preset.layout != .full && preset.main == preset.secondary }
    private var isValid: Bool { !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasConflict }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Preset") {
                    TextField("Name", text: $preset.name)
                        .accessibilityIdentifier("preset-name")
                    Picker("Layout", selection: $preset.layout) {
                        ForEach(SplitLayout.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Inputs") {
                    Picker(preset.layout == .full || preset.layout.isPIP ? "Main input" : "Left input", selection: $preset.main) {
                        ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
                    }
                    if preset.layout != .full {
                        Picker(preset.layout.isPIP ? "Inset input" : "Right input", selection: $preset.secondary) {
                            ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
                        }
                        Button {
                            let main = preset.main
                            preset.main = preset.secondary
                            preset.secondary = main
                        } label: { Label("Swap inputs", systemImage: "arrow.left.arrow.right") }
                    }
                }
                Section("Preview") { LayoutPreview(preset: preset) }
                if hasConflict { StatusBanner(message: "Choose two different inputs for a split layout.") }
                if let error { StatusBanner(message: error, isError: true) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save preset") {
                    do { try preset.validate(); save(preset) }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .accessibilityIdentifier("save-preset")
            }.padding()
        }
        .frame(width: 500, height: 570)
    }
}

private struct HotkeysView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Open preset remote") {
                    ShortcutRecorder(preset: DisplayPreset(id: AppStore.remoteID, name: "Preset remote", layout: .full, main: .dp, secondary: .hdmi, shortcut: store.configuration.effectiveRemoteShortcut), capture: { store.setRemoteShortcut($0) }, recordingChanged: { store.shortcutRecording($0) })
                        .frame(width: 145, height: 28)
                    Button("Reset") {
                        store.setRemoteShortcut(PresetShortcut(keyCode: 49, modifiers: PresetShortcut.control | PresetShortcut.option, keyLabel: "Space"))
                    }
                }
                if let issue = store.hotkeyIssues[AppStore.remoteID] { StatusBanner(message: issue) }
            } header: { Text("Preset remote") }
            footer: { Text("Click Record, then press a key with Control, Option, or Command. Escape cancels.") }
            Section("Preset shortcuts") {
                if store.configuration.presets.isEmpty { Text("Create a preset to assign a shortcut.").foregroundStyle(.secondary) }
                ForEach(store.configuration.presets) { preset in
                    LabeledContent {
                        ShortcutRecorder(preset: preset, capture: { store.setShortcut($0, for: preset.id) }, recordingChanged: { store.shortcutRecording($0) })
                            .frame(width: 145, height: 28)
                        IconButton(icon: "xmark.circle", help: "Clear hotkey for \(preset.name)", role: .destructive) {
                            store.setShortcut(nil, for: preset.id)
                        }
                        .disabled(preset.shortcut == nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            if let issue = store.hotkeyIssues[preset.id] {
                                Text(issue).font(.caption).foregroundStyle(warningColor)
                            } else if store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput) {
                                Text("Inactive: this preset hides this Mac").font(.caption).foregroundStyle(.secondary)
                            } else if !store.configured {
                                Text("Complete monitor setup to activate").font(.caption).foregroundStyle(.secondary)
                            } else if preset.shortcut != nil {
                                Text("Active globally").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(store.busy)
            Text("No Accessibility or Input Monitoring permission is needed.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("appearance-picker")
                Toggle("Launch OpenDDPM at login", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
            }
            Section("About OpenDDPM") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("A native menu bar companion for Dell monitor inputs and split layouts.")
                LabeledContent("Monitor support", value: "Dell U4025QW")
                Text("Uses the monitor’s own Picture-by-Picture and Picture-in-Picture controls over DDC/CI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Open source") {
                Link("GitHub repository", destination: URL(string: "https://github.com/prBigBrother/OpenDDPM")!)
                Link("Download releases", destination: URL(string: "https://github.com/prBigBrother/OpenDDPM/releases")!)
                Text("Independent software. Not affiliated with Dell.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
