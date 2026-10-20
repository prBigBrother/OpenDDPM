import SwiftUI
import AppKit

struct PresetRemoteView: View {
    @ObservedObject var store: AppStore
    private var target: DisplayPreset? { store.configuration.presets.first { $0.id == store.transition.desiredPresetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.configuration.monitorName.isEmpty ? "Preset remote" : store.configuration.monitorName).font(.headline)
                    Text("One selection. Your whole workspace.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.openWindow?() } label: { Image(systemName: "gearshape") }.help("Configure presets")
            }
            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.progress).font(.callout).textSelection(.enabled)
                Spacer()
                if let elapsed = store.transition.elapsed { Text(String(format: "%.1f s", elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("remote-progress")
            if let error = store.error ?? store.transition.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if store.busy, let target { Text("Selected: \(target.name) · choose another preset to change the target").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(store.configuration.presets) { preset in
                        let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                        let selected = store.busy && store.transition.desiredPresetID == preset.id
                        let verified = !store.busy && store.lastPresetID == preset.id
                        Button { store.apply(preset) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                LayoutPreview(preset: preset, compact: true)
                                Text(preset.name).font(.headline).lineLimit(2)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(blocked ? "Hides this Mac" : selected ? "Selected" : verified ? "Verified ✓" : "Select preset")
                                    Spacer()
                                    if let shortcut = preset.shortcut { Text(shortcut.display) }
                                }.font(.caption2).foregroundStyle(selected || verified ? Color.cyan : Color.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(selected || verified ? Color.cyan.opacity(0.1) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected || verified ? Color.cyan.opacity(0.7) : Color.white.opacity(0.12)))
                        }.buttonStyle(.plain).disabled(blocked || !store.configured)
                            .accessibilityIdentifier("remote-preset-\(preset.id.uuidString)")
                            .contextMenu {
                                Button("Copy Apple Shortcuts URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("openddpm://apply?id=\(preset.id.uuidString)", forType: .string)
                                }
                            }
                    }
                }
            }
            Divider()
            HStack {
                Button("Previous preset") { store.previous() }.disabled(store.previousPreset == nil)
                Button("Retry verification") { store.refresh() }.disabled(store.busy)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([TransitionJournal.standard.url]) } label: { Image(systemName: "doc.text.magnifyingglass") }.help("Show transition journal")
            }
            if let error = TransitionJournal.standard.lastError { Text("Journal unavailable: \(error)").font(.caption).foregroundStyle(.orange) }
        }.padding(20).frame(minWidth: 380, minHeight: 360).background(Color(red: 0.09, green: 0.105, blue: 0.15))
    }
}
