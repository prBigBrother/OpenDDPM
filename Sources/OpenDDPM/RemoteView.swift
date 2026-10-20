import SwiftUI
import AppKit

struct PresetRemoteView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @ViewState private var shortcutPreset: DisplayPreset?
    private var target: DisplayPreset? { store.configuration.presets.first { $0.id == store.transition.desiredPresetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.configuration.monitorName.isEmpty ? "Preset remote" : store.configuration.monitorName)
                        .font(.headline)
                    Text("One selection. Your whole workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ModernIconButton(icon: "gearshape", help: "Configure presets & settings") {
                    store.openWindow?()
                }
            }
            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.progress).font(.callout).textSelection(.enabled)
                Spacer()
                if let elapsed = store.transition.elapsed {
                    Text(String(format: "%.1f s", elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("remote-progress")

            if let error = store.error ?? store.transition.error {
                StatusBanner(message: error, isError: true)
            }
            if store.busy, let target {
                Text("Selected: \(target.name) · choose another preset to change the target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.configuration.presets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No presets available")
                        .font(.headline)
                    Text("Set up your first layout in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        store.openWindow?()
                    }
                    .buttonStyle(.borderedProminent)
                    .focusable(false)
                    .pointerCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(store.configuration.presets) { preset in
                            let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                            let selected = store.busy && store.transition.desiredPresetID == preset.id
                            let verified = !store.busy && store.lastPresetID == preset.id
                            RemotePresetCard(
                                preset: preset,
                                blocked: blocked,
                                selected: selected,
                                verified: verified,
                                configured: store.configured,
                                onApply: { store.apply(preset) }
                            )
                            .accessibilityIdentifier("remote-preset-\(preset.id.uuidString)")
                            .contextMenu {
                                Button("Set up Apple Shortcut…") { shortcutPreset = preset }
                                Button("Copy preset link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("openddpm://apply?id=\(preset.id.uuidString)", forType: .string)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    store.previous()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                        Text(store.previousPreset.map { "Previous (\($0.name))" } ?? "Previous preset")
                    }
                }
                .buttonStyle(.bordered)
                .focusable(false)
                .pointerCursor()
                .disabled(store.previousPreset == nil || store.busy)
                .help(store.previousPreset.map { "Switch back to \($0.name)" } ?? "No previous preset available")

                Button {
                    store.refresh()
                } label: {
                    Label("Retry verification", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .focusable(false)
                .pointerCursor()
                .disabled(store.busy)

                Spacer()

                ModernIconButton(icon: "doc.text.magnifyingglass", help: "Show transition journal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TransitionJournal.standard.url])
                }
            }
            if let error = TransitionJournal.standard.lastError {
                StatusBanner(message: "Journal unavailable: \(error)", isError: false)
            }
        }
        .sheet(item: $shortcutPreset) { ShortcutSetupView(preset: $0) }
        .padding(20)
        .frame(minWidth: 420, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
    }
}

private struct RemotePresetCard: View {
    let preset: DisplayPreset
    let blocked: Bool
    let selected: Bool
    let verified: Bool
    let configured: Bool
    let onApply: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: onApply) {
            VStack(alignment: .leading, spacing: 9) {
                LayoutPreview(preset: preset, compact: true)
                Text(preset.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if blocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text("Hides this Mac")
                    } else if selected {
                        ProgressView().controlSize(.small)
                        Text("Applying…")
                    } else if verified {
                        Image(systemName: "checkmark")
                        Text("Verified")
                    } else {
                        Text("Select preset")
                    }
                    Spacer()
                    if let shortcut = preset.shortcut {
                        Text(shortcut.display)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .font(.caption2)
                .foregroundStyle(selected || verified ? accent : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                selected || verified
                    ? accent.opacity(isHovered ? 0.16 : 0.1)
                    : (isHovered ? Color.primary.opacity(0.075) : Color.primary.opacity(0.045)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        selected || verified
                            ? accent.opacity(isHovered ? 0.9 : 0.7)
                            : (isHovered ? Color.primary.opacity(0.24) : Color.primary.opacity(0.12)),
                        lineWidth: selected || verified ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointerCursor()
        .disabled(blocked || !configured)
        .opacity(blocked ? 0.55 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(blocked ? "This preset hides this Mac (blocked by 'Keep this Mac visible')" : "Apply preset '\(preset.name)'")
    }
}
