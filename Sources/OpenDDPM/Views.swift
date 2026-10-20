import SwiftUI

// Use the property-wrapper type explicitly. New SDKs also introduce a State
// macro whose plugin is absent from standalone Command Line Tools installations.
typealias ViewState<Value> = SwiftUI.State<Value>

let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.22, green: 0.84, blue: 0.91, alpha: 1)
        : NSColor(srgbRed: 0.02, green: 0.43, blue: 0.51, alpha: 1)
})
let violet = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.62, green: 0.53, blue: 0.99, alpha: 1)
        : NSColor(srgbRed: 0.39, green: 0.28, blue: 0.72, alpha: 1)
})

let warningColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.68, blue: 0.25, alpha: 1)
        : NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1)
})

let errorColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)
        : NSColor(srgbRed: 0.82, green: 0.15, blue: 0.15, alpha: 1)
})

struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hasPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && isEnabled && !hasPushed {
                    hasPushed = true
                    NSCursor.pointingHand.push()
                } else if (!inside || !isEnabled) && hasPushed {
                    hasPushed = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hasPushed {
                    hasPushed = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}

struct ModernIconButton: View {
    var icon: String
    var help: String? = nil
    var role: ButtonRole? = nil
    var action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(role == .destructive ? (isHovered ? errorColor : Color.secondary) : (isHovered ? Color.primary : Color.secondary))
                .frame(width: 28, height: 28)
                .background(isHovered ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .help(help ?? "")
    }
}

struct StatusBanner: View {
    var message: String
    var isError: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isError ? errorColor : warningColor)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? errorColor : warningColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? errorColor : warningColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((isError ? errorColor : warningColor).opacity(0.25)))
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
        .accessibilityLabel(preset.detail)
    }
    private func pane(_ title: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.19))
            .overlay(Text(title).font(compact ? .caption.bold() : .title2.bold()).foregroundStyle(color))
    }
}

struct ConfigurationView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @ViewState private var isRefreshHovered = false

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
                navigation("automation", "Apple Home", "house")
                navigation("about", "About OpenDDPM", "info.circle")
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label(store.configured ? store.configuration.monitorName : "Setup required", systemImage: store.configured ? "checkmark.circle.fill" : "circle.dashed").font(.caption.bold()).foregroundStyle(accent)
                    Text(store.configured ? "This Mac · \(store.configuration.localInput.title)" : "Identify your Mac’s cable to begin.").font(.caption).foregroundStyle(.secondary)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")").font(.caption2).foregroundStyle(.tertiary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }.padding(20).frame(width: 230).background(Color(nsColor: .underPageBackgroundColor))
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
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isRefreshHovered ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(isRefreshHovered ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(store.busy)
                    .onHover { isRefreshHovered = $0 }
                    .help("Refresh monitor status")
                }.padding(14)
            }.frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 920, minHeight: 650)
        .tint(accent)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
        .onAppear {
            NSApp.appearance = AppAppearance(rawValue: appearanceRaw)?.nsAppearance
        }
        .onChange(of: appearanceRaw) { rawValue in
            NSApp.appearance = AppAppearance(rawValue: rawValue)?.nsAppearance
        }
        .alert("OpenDDPM", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func navigation(_ page: String, _ title: String, _ icon: String) -> some View {
        NavigationItemButton(
            page: page,
            title: title,
            icon: icon,
            isSelected: store.selectedPage == page
        ) {
            store.selectedPage = page
        }
    }
}

private struct NavigationItemButton: View {
    let page: String
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    isSelected
                        ? accent.opacity(isHovered ? 0.16 : 0.12)
                        : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .foregroundStyle(isSelected ? accent : (isHovered ? Color.primary : Color.secondary))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .focusable(false)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .accessibilityIdentifier("nav-\(page)")
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
                    }
                    .labelsHidden()
                    .frame(maxWidth: 390)
                    .pointerCursor()
                }
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Label("Discover", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                .disabled(store.busy)
                .accessibilityIdentifier("discover")
            }
            if let status = store.status { Text("Now showing: \(status.description)").font(.caption).foregroundStyle(.secondary) }
            Text("Designed and tested for Dell U4025QW. DDC/CI must be enabled in the monitor’s on-screen menu.").font(.caption).foregroundStyle(.secondary)
        }
        section("2", "Identify this Mac’s input") {
            HStack(spacing: 10) {
                ForEach(VideoInput.allCases) { input in
                    InputCard(
                        input: input,
                        isSelected: store.configuration.localInput == input,
                        isDetected: input == store.status?.localInput
                    ) {
                        store.configuration.localInput = input
                        store.configuration.inputConfirmed = false
                    }
                }
            }
            Text("Follow the cable from this Mac to the monitor. Detection is a suggestion; confirm the physical input. This step never switches your display.").font(.caption).foregroundStyle(.secondary)
            Toggle("Keep this Mac visible", isOn: $store.configuration.keepLocalVisible)
                .pointerCursor()
            Text("When enabled, presets that exclude \(store.configuration.localInput.title) are blocked. Turn it off only when you intend to hide this Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.configuration.inputConfirmed { Label("Input confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(accent) }
                Spacer()
                Button("Confirm input & view presets") {
                    store.confirmInput()
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
                .disabled(store.configuration.monitorSerial.isEmpty || store.busy)
                .accessibilityIdentifier("confirm-input")
            }
        }.disabled(store.busy)
    }
}

private struct InputCard: View {
    let input: VideoInput
    let isSelected: Bool
    let isDetected: Bool
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: input == .thunderbolt ? "bolt.fill" : "cable.connector")
                        .font(.title2)
                        .foregroundStyle(isSelected ? accent : Color.primary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(accent)
                            .offset(x: 16, y: -4)
                    }
                }
                Text(input.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : Color.primary)
                HStack(spacing: 4) {
                    if isDetected {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                    }
                    Text(isDetected ? "Detected connection" : (isSelected ? "Selected input" : "Select cable"))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? accent : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                isSelected
                    ? accent.opacity(isHovered ? 0.18 : 0.14)
                    : (isHovered ? Color.primary.opacity(0.065) : Color.primary.opacity(0.035)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected
                            ? accent
                            : (isHovered ? Color.primary.opacity(0.2) : Color.primary.opacity(0.08)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .accessibilityIdentifier("input-\(input.rawValue)")
    }
}

private struct PresetsView: View {
    @ObservedObject var store: AppStore
    @ViewState private var editing: DisplayPreset?
    @ViewState private var shortcutPreset: DisplayPreset?
    @ViewState private var draggingPresetID: UUID?
    @ViewState private var dropTargetID: UUID?
    @ViewState private var previewOrderIDs: [UUID]?
    @ViewState private var cardFrames: [UUID: CGRect] = [:]
    @ViewState private var dragLocation: CGPoint = .zero
    @ViewState private var dragGrabOffset: CGPoint = .zero
    @ViewState private var dragCardFrame: CGRect = .zero

    private var displayedPresets: [DisplayPreset] {
        guard let previewOrderIDs else { return store.configuration.presets }
        let presets = Dictionary(uniqueKeysWithValues: store.configuration.presets.map { ($0.id, $0) })
        return previewOrderIDs.compactMap { presets[$0] }
    }

    var body: some View {
        HStack {
            title("One click. New workspace.", subtitle: "Create layouts for the way you move between machines.")
            Spacer()
            Button {
                editing = DisplayPreset(name: "New preset", layout: .equal, main: store.configuration.localInput, secondary: store.configuration.localInput == .dp ? .thunderbolt : .dp)
            } label: {
                Label("New preset", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .pointerCursor()
            .disabled(store.busy)
            .accessibilityIdentifier("new-preset")
        }
        if !store.configured {
            StatusBanner(message: "Complete monitor and input setup before applying presets.", isError: false)
        }
        if displayedPresets.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("No presets configured yet")
                    .font(.headline)
                Text("Create layouts to quickly change inputs and view modes across your machines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    editing = DisplayPreset(name: "New preset", layout: .equal, main: store.configuration.localInput, secondary: store.configuration.localInput == .dp ? .thunderbolt : .dp)
                } label: {
                    Label("Create first preset", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(displayedPresets) { preset in
                    let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                    PresetGridCard(
                        preset: preset,
                        blocked: blocked,
                        isSelected: store.transition.desiredPresetID == preset.id && store.busy,
                        isVerified: store.lastPresetID == preset.id,
                        isDropTarget: dropTargetID == preset.id,
                        storeBusy: store.busy,
                        configured: store.configured,
                        onEdit: { editing = preset },
                        onShortcut: { shortcutPreset = preset },
                        onDelete: { store.deletePreset(preset.id) },
                        onApply: { store.apply(preset) }
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PresetCardFramesPreferenceKey.self, value: [preset.id: proxy.frame(in: .named("preset-grid"))])
                        }
                    }
                    .opacity(draggingPresetID == preset.id ? 0 : 1)
                    .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("preset-grid"))
                        .onChanged { value in updateDrag(for: preset.id, value: value) }
                        .onEnded { _ in finishDrag() })
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: displayedPresets.map(\.id))
                }
            }
            .coordinateSpace(name: "preset-grid")
            .onPreferenceChange(PresetCardFramesPreferenceKey.self) { cardFrames = $0 }
            .overlay(alignment: .topLeading) {
                if let draggingPresetID, let preset = store.configuration.presets.first(where: { $0.id == draggingPresetID }), dragCardFrame.width > 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        LayoutPreview(preset: preset, compact: true)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        HStack { Spacer(); Text("Drop to place").font(.caption2.weight(.semibold)).foregroundStyle(accent) }
                    }
                    .padding(15)
                    .frame(width: dragCardFrame.width, height: dragCardFrame.height)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(0.95), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 9)
                    .position(x: dragLocation.x - dragGrabOffset.x + dragCardFrame.width / 2,
                              y: dragLocation.y - dragGrabOffset.y + dragCardFrame.height / 2)
                    .allowsHitTesting(false)
                    .zIndex(10)
                }
            }
        }
        HStack {
            Button("Import presets…") { store.importConfiguration() }
                .buttonStyle(.bordered)
                .pointerCursor()
            Button("Export presets…") { store.exportConfiguration() }
                .buttonStyle(.bordered)
                .pointerCursor()
            Spacer()
            Text("Drag a card to its new position · saved automatically").font(.caption).foregroundStyle(.secondary)
        }.disabled(store.busy)
        .sheet(item: $shortcutPreset) { ShortcutSetupView(preset: $0) }
        .sheet(item: $editing) { preset in PresetEditor(preset: preset) { store.savePreset($0); editing = nil } cancel: { editing = nil } }
    }

    private func updateDrag(for id: UUID, value: DragGesture.Value) {
        guard !store.busy else { return }
        if draggingPresetID == nil {
            guard let frame = cardFrames[id] else { return }
            draggingPresetID = id
            previewOrderIDs = store.configuration.presets.map(\.id)
            dragCardFrame = frame
            dragGrabOffset = CGPoint(x: value.location.x - frame.minX, y: value.location.y - frame.minY)
        }
        guard draggingPresetID == id else { return }
        dragLocation = value.location

        let target = cardFrames
            .filter { $0.key != id && $0.value.contains(value.location) }
            .min { lhs, rhs in
                hypot(lhs.value.midX - value.location.x, lhs.value.midY - value.location.y)
                    < hypot(rhs.value.midX - value.location.x, rhs.value.midY - value.location.y)
            }?.key
        guard let target, target != dropTargetID,
              var order = previewOrderIDs,
              let sourceIndex = order.firstIndex(of: id),
              let targetIndex = order.firstIndex(of: target), sourceIndex != targetIndex else {
            if target == nil { withAnimation(.easeOut(duration: 0.12)) { dropTargetID = nil } }
            return
        }

        dropTargetID = target
        order.remove(at: sourceIndex)
        let destination = min(targetIndex, order.count)
        order.insert(id, at: destination)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { previewOrderIDs = order }
    }

    private func finishDrag() {
        if let previewOrderIDs, previewOrderIDs != store.configuration.presets.map(\.id) {
            store.reorderPresets(previewOrderIDs)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            draggingPresetID = nil
            dropTargetID = nil
            previewOrderIDs = nil
        }
    }
}

private struct PresetGridCard: View {
    let preset: DisplayPreset
    let blocked: Bool
    let isSelected: Bool
    let isVerified: Bool
    let isDropTarget: Bool
    let storeBusy: Bool
    let configured: Bool
    let onEdit: () -> Void
    let onShortcut: () -> Void
    let onDelete: () -> Void
    let onApply: () -> Void
    @ViewState private var isCardHovered = false
    @ViewState private var isMenuHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LayoutPreview(preset: preset, compact: true)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name).font(.headline)
                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCardHovered ? accent : Color.secondary.opacity(0.45))
                        .help("Drag card to reorder")
                        .padding(.trailing, 2)
                    Menu {
                        Button("Edit preset", action: onEdit)
                        Button("Set up Apple Shortcut…", action: onShortcut)
                        Divider()
                        Button("Delete preset", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isMenuHovered ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(isMenuHovered ? Color.primary.opacity(0.08) : Color.clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .pointerCursor()
                    .onHover { isMenuHovered = $0 }
                    .disabled(storeBusy)
                    .help("Preset options")
                }
            }
            HStack {
                if blocked {
                    Label("Hides this Mac", systemImage: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                } else if isVerified {
                    Label("Verified", systemImage: "checkmark").font(.caption2).foregroundStyle(accent)
                }
                Spacer()
                Button(action: onApply) {
                    HStack(spacing: 5) {
                        if isSelected {
                            ProgressView().controlSize(.small)
                            Text("Applying…")
                        } else if isVerified {
                            Image(systemName: "checkmark")
                            Text("Applied")
                        } else {
                            Text("Apply")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                .disabled(blocked || !configured || storeBusy)
            }
        }
        .padding(15)
        .background(
            isCardHovered ? Color.primary.opacity(0.055) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(
                    isDropTarget
                        ? accent.opacity(0.98)
                        : (isCardHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.09)),
                    lineWidth: isDropTarget ? 2 : 1
                )
                .shadow(color: isDropTarget ? accent.opacity(0.34) : .clear, radius: 12)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if isDropTarget {
                Capsule().fill(accent).frame(width: 4, height: 48).padding(.leading, 2)
                    .shadow(color: accent.opacity(0.75), radius: 7)
                    .transition(.opacity.combined(with: .scale))
                    .allowsHitTesting(false)
            }
        }
        .onHover { isCardHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isCardHovered)
    }
}

private struct PresetCardFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct PresetEditor: View {
    @ViewState var preset: DisplayPreset
    var save: (DisplayPreset) -> Void
    var cancel: () -> Void
    @ViewState private var error: String?

    private var hasConflict: Bool {
        preset.layout != .full && preset.main == preset.secondary
    }

    private var isValid: Bool {
        !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasConflict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Design a preset").font(.title2.bold())
            LayoutPreview(preset: preset)
            TextField("Preset name", text: $preset.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("preset-name")
            Picker("Layout", selection: $preset.layout) {
                ForEach(SplitLayout.allCases) { Text($0.title).tag($0) }
            }
            .pointerCursor()
            Picker(preset.layout.isPIP ? "Main input" : "Left / main input", selection: $preset.main) {
                ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
            }
            .pointerCursor()
            if preset.layout != .full {
                Picker(preset.layout.isPIP ? "Inset input" : "Right / secondary input", selection: $preset.secondary) {
                    ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
                }
                .pointerCursor()
            }
            if hasConflict {
                StatusBanner(message: "Choose two different inputs for a split layout.", isError: false)
            }
            if let error {
                StatusBanner(message: error, isError: true)
            }
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Spacer()
                Button("Save preset") {
                    do {
                        try preset.validate()
                        save(preset)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
                .disabled(!isValid)
                .accessibilityIdentifier("save-preset")
            }
        }
        .padding(28)
        .frame(width: 470)
        .tint(accent)
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
            Button("Default") {
                store.setRemoteShortcut(PresetShortcut(keyCode: 49, modifiers: PresetShortcut.control | PresetShortcut.option, keyLabel: "Space"))
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
        if let issue = store.hotkeyIssues[AppStore.remoteID] {
            StatusBanner(message: issue, isError: false)
        }
        Text("Click Record, then press a key with Control, Option, or Command. Escape cancels.").font(.callout).foregroundStyle(.secondary)
        VStack(spacing: 0) {
            ForEach(store.configuration.presets) { preset in
                let blocked = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.name).font(.headline)
                        Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        if let issue = store.hotkeyIssues[preset.id] {
                            Text(issue).font(.caption).foregroundStyle(warningColor)
                        } else if blocked {
                            Text("Inactive: this preset hides this Mac").font(.caption).foregroundStyle(.secondary)
                        } else if !store.configured {
                            Text("Complete monitor setup to activate").font(.caption).foregroundStyle(.secondary)
                        } else if preset.shortcut != nil {
                            Text("Active globally").font(.caption).foregroundStyle(accent)
                        }
                    }
                    Spacer()
                    ShortcutRecorder(preset: preset, capture: { store.setShortcut($0, for: preset.id) }, recordingChanged: { store.shortcutRecording($0) }).frame(width: 145, height: 28)
                    ModernIconButton(icon: "xmark.circle", help: "Clear this hotkey", role: .destructive) {
                        store.setShortcut(nil, for: preset.id)
                    }
                    .disabled(preset.shortcut == nil)
                }.padding(18)
                if preset.id != store.configuration.presets.last?.id { Divider().padding(.horizontal, 18) }
            }
        }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.09))).disabled(store.busy)
        Label("No Accessibility or Input Monitoring permission is needed.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
    }
}

private struct AboutView: View {
    @ObservedObject var store: AppStore
    @AppStorage("OpenDDPM.appearance") private var appearanceRaw = AppAppearance.system.rawValue
    var body: some View {
        title("OpenDDPM", subtitle: "A small, open-source menu bar companion for your ultrawide workspace.")
        section("", "Built to stay out of the way") {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance.rawValue) }
            }
            .pickerStyle(.segmented)
            .pointerCursor()
            .accessibilityIdentifier("appearance-picker")
            Text("Pick a preset from the menu bar, or create one here. Layout changes use the monitor’s own Picture-by-Picture and Picture-in-Picture controls.").foregroundStyle(.secondary)
            Toggle("Launch OpenDDPM at login", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
                .pointerCursor()
        }
        section("", "Built-in monitor control") {
            Label("Standalone native DDC/CI driver", systemImage: "cable.connector").foregroundStyle(accent)
            Text("OpenDDPM communicates directly with the monitor using macOS IOKit. No external monitor-control application, CLI installation, Python, or Homebrew is required.").font(.callout).foregroundStyle(.secondary)
            Text("Apple Silicon uses IOAVService; Intel uses the I2C framebuffer interface. Enable DDC/CI in the monitor’s own menu.").font(.caption).foregroundStyle(.secondary)
            Text("Universal app for Apple Silicon and Intel · macOS 13 or newer").font(.caption).foregroundStyle(.secondary)
        }
        section("", "Open source") {
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/prBigBrother/OpenDDPM")!) {
                    Label("GitHub repository", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Link(destination: URL(string: "https://github.com/prBigBrother/OpenDDPM/releases")!) {
                    Label("Download releases", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Text("Independent software. Not affiliated with Dell. Monitor support is currently validated on the U4025QW.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

func title(_ text: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) { Text(text).font(.system(size: 27, weight: .bold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
}

func section<Content: View>(_ number: String, _ heading: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 15) {
        HStack(spacing: 10) {
            if !number.isEmpty { Text(number).font(.caption.bold()).frame(width: 23, height: 23).background(accent.opacity(0.16), in: Circle()).foregroundStyle(accent) }
            Text(heading).font(.headline)
        }
        content()
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.09)))
}
