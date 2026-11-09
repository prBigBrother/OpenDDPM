import AppKit
import SwiftUI
import Combine

/// Optional classic system HUD. The modern HUD uses native Liquid Glass in an
/// app-owned nonactivating window, identified as OpenDDPM in the style picker.
@objc private protocol OpenDDPMSystemOSD {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(_ image: Int64, onDisplayID display: UInt32, priority: UInt32,
                   msecUntilFade: UInt32, filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
}

@MainActor
final class BrightnessOSD: ObservableObject {
    @Published private(set) var issue: String?
    private var connection: NSXPCConnection?
    private let modernHUD = BrightnessHUDWindow()
    private let defaults: UserDefaults
    @Published private(set) var style: BrightnessHUDStyle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback: BrightnessHUDStyle
        if #available(macOS 26.0, *) { fallback = .modern } else { fallback = .system }
        self.style = defaults.string(forKey: "OpenDDPM.brightnessHUDStyle").flatMap(BrightnessHUDStyle.init(rawValue:)) ?? fallback
    }
    func setStyle(_ style: BrightnessHUDStyle) {
        self.style = style
        defaults.set(style.rawValue, forKey: "OpenDDPM.brightnessHUDStyle")
        if style == .system { modernHUD.hide() }
    }

    deinit { connection?.invalidate() }

    func show(value: Double, displayID: CGDirectDisplayID) {
        guard value.isFinite, displayID != 0, CGDisplayIsOnline(displayID) != 0 else { return }
        if style == .modern {
            issue = modernHUD.show(value: value, displayID: displayID) ? nil : "The selected display is unavailable for the brightness indicator."
            return
        }
        let active: NSXPCConnection
        if let connection { active = connection }
        else {
            active = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            active.remoteObjectInterface = NSXPCInterface(with: OpenDDPMSystemOSD.self)
            active.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.issue = "The native macOS brightness indicator is unavailable on this system."
                }
            }
            active.interruptionHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection?.invalidate()
                    self?.connection = nil
                }
            }
            connection = active
            active.resume()
        }
        guard let proxy = active.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            DispatchQueue.main.async {
                self?.issue = "macOS rejected its native brightness indicator request. Brightness control remains available."
            }
        }) as? OpenDDPMSystemOSD else {
            issue = "The native macOS brightness indicator is unavailable on this system."
            return
        }
        issue = nil
        proxy.showImage(1, onDisplayID: displayID, priority: 500, msecUntilFade: 1200,
                        filledChiclets: UInt32(min(100, max(0, value)).rounded()), totalChiclets: 100, locked: false)
    }
}


enum BrightnessHUDStyle: String, CaseIterable {
    case modern, system
    var title: String { self == .modern ? "Modern OpenDDPM" : "Classic system" }
}

@MainActor
private final class BrightnessHUDState: ObservableObject {
    @Published var value = 0.0
    @Published var displayName = "Brightness"
}

private struct BrightnessHUDContent: View {
    @ObservedObject var state: BrightnessHUDState
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 11))
                    .frame(width: 12, height: 18)
                    .offset(y: -2.5)
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Capsule().fill(.white.opacity(0.18))
                            .frame(height: 4)
                        Capsule().fill(.white)
                            .frame(width: geometry.size.width * state.value / 100, height: 4)
                        HStack(spacing: 0) {
                            ForEach(0..<17) { _ in
                                Circle().fill(.white.opacity(0.13))
                                    .frame(width: 1.5, height: 1.5)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .offset(y: 7)
                    }
                }
                .frame(height: 9)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .frame(width: 18, height: 18)
                    .offset(y: -2.5)
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 292, height: 64)
        .animation(.easeOut(duration: 0.08), value: state.value)
    }
    var body: some View {
        content
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.displayName), brightness \(Int(state.value.rounded())) percent")
    }
}

@MainActor
private final class BrightnessHUDWindow {
    private let state = BrightnessHUDState()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var presentation = UUID()

    private func makeContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 302, height: 74))
        let content = NSHostingView(rootView: BrightnessHUDContent(state: state))
        content.frame = NSRect(x: 0, y: 0, width: 292, height: 64)
        let glass: NSView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: NSRect(x: 5, y: 5, width: 292, height: 64))
            effect.style = .regular
            effect.cornerRadius = 26
            effect.tintColor = NSColor(white: 0.08, alpha: 0.35)
            effect.contentView = content
            glass = effect
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 5, y: 5, width: 292, height: 64))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 26
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            glass = effect
        }
        glass.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(glass)
        return container
    }

    func show(value: Double, displayID: UInt32) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return false }
        dismissal?.cancel()
        let token = UUID()
        presentation = token
        state.value = min(100, max(0, value))
        state.displayName = screen.localizedName
        let window: NSPanel
        if let panel { window = panel }
        else {
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 302, height: 74),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = makeContentView()
            window.setAccessibilityLabel("OpenDDPM brightness indicator")
            panel = window
        }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.maxX - 302 - 12, y: frame.maxY - 74 - 12))
        window.alphaValue = 1
        window.orderFrontRegardless()
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
            guard let self, self.presentation == token, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.presentation == token else { return }
                    self.panel?.orderOut(nil)
                }
            }
        }
        return true
    }
    func hide() {
        dismissal?.cancel()
        presentation = UUID()
        panel?.orderOut(nil)
    }
}
