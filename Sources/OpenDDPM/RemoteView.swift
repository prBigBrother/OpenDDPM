import SwiftUI
import AppKit

struct PresetRemoteView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @ViewState private var shortcutPreset: DisplayPreset?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "display").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.configuration.monitorName.isEmpty ? "Monitor presets" : store.configuration.monitorName)
                        .font(.headline)
                    Text(store.progress).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("remote-progress")
                    if store.busy {
                        Text("Select another preset to change the target.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if store.busy { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()

            if !store.configured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your monitor and this Mac’s input to use presets.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Set up monitor & inputs") {
                        store.selectedPage = "setup"
                        store.openWindow?()
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.configuration.presets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x1").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No presets yet").font(.headline)
                    Button("Create a preset") {
                        store.selectedPage = "presets"
                        store.openWindow?()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.configuration.presets) { preset in
                        RemotePresetRow(preset: preset, store: store)
                            .contextMenu {
                                Button("Set up Apple Shortcut…") { shortcutPreset = preset }
                                Button("Copy preset link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("openddpm://apply?id=\(preset.id.uuidString)", forType: .string)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            if let error = store.error ?? store.transition.error {
                Divider()
                StatusBanner(message: error, isError: true).padding()
            }
            if let error = TransitionJournal.standard.lastError {
                Divider()
                StatusBanner(message: "Journal unavailable: \(error)").padding()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.previous() } label: {
                    Label("Previous preset", systemImage: "arrow.uturn.backward")
                }
                .disabled(store.previousPreset == nil || store.busy)
                .help(store.previousPreset.map { "Switch back to \($0.name)" } ?? "No previous preset available")

                Button { store.refresh() } label: {
                    Label("Verify monitor state", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy)
                .help("Read the monitor’s current state again")

                Button { store.togglePower() } label: {
                    Label(store.isPoweredOn ? "Sleep monitor" : "Wake monitor", systemImage: store.isPoweredOn ? "moon" : "sun.max")
                }
                .disabled(store.busy || !store.configured)
                .help(store.isPoweredOn ? "Put the monitor in standby" : "Wake the monitor")

                Menu {
                    Button("Configure OpenDDPM…") { store.openWindow?() }
                    Divider()
                    Button("Show transition journal") {
                        NSWorkspace.shared.activateFileViewerSelecting([TransitionJournal.standard.url])
                    }
                } label: { Label("Settings & diagnostics", systemImage: "gearshape") }
                .help("Settings & diagnostics")
            }
        }
        .sheet(item: $shortcutPreset) { ShortcutSetupView(preset: $0) }
        .frame(minWidth: 400, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
    }
}

private struct RemotePresetRow: View {
    let preset: DisplayPreset
    @ObservedObject var store: AppStore

    private var hidesLocal: Bool { !preset.includes(store.configuration.localInput) }
    private var blocked: Bool { store.configuration.keepLocalVisible && hidesLocal }
    private var selected: Bool { store.busy && store.transition.desiredPresetID == preset.id }
    private var verified: Bool { !store.busy && store.lastPresetID == preset.id }
    private var stateDescription: String {
        blocked ? "Blocked: hides this Mac" : selected ? "Applying" : verified ? "Verified" : hidesLocal ? "Hides this Mac" : "Ready"
    }

    var body: some View {
        Button { store.apply(preset) } label: {
            HStack(spacing: 12) {
                LayoutPreview(preset: preset, compact: true).frame(width: 82)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                    if hidesLocal {
                        Label(blocked ? "Blocked · hides this Mac" : "Hides this Mac", systemImage: blocked ? "lock" : "eye.slash")
                            .font(.caption).foregroundStyle(warningColor)
                    }
                }
                Spacer(minLength: 4)
                if let shortcut = preset.shortcut {
                    Text(shortcut.display).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if selected {
                    ProgressView().controlSize(.small)
                } else if verified {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked || !store.configured)
        .accessibilityLabel("\(preset.name), \(preset.detail)")
        .accessibilityValue(stateDescription)
        .accessibilityIdentifier("remote-preset-\(preset.id.uuidString)")
        .help(blocked ? "Blocked by Keep this Mac visible" : "Apply \(preset.name)")
    }
}
