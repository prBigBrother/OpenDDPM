import AppKit
import SwiftUI
import Combine

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "OpenDDPM")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "OpenDDPM · Monitor presets"
        store.openWindow = { [weak self] in self?.showWindow() }
        store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateMenu() } }.store(in: &subscriptions)
        updateMenu()
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.statusItem.button?.performClick(nil) }
        }
        if !store.configured || CommandLine.arguments.contains("--show-window") { showWindow() }
        if store.dependencyInstalled {
            store.startBetterDisplay()
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); store.refresh() }
        }
    }
    func updateMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "OpenDDPM", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        let state = NSMenuItem(title: store.busy ? store.progress : (store.status?.description ?? "Configure monitor & inputs…"), action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        for preset in store.configuration.presets {
            let hidden = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
            let item = NSMenuItem(title: preset.name + "  ·  " + preset.detail + (hidden ? "  🔒" : ""), action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = preset.id.uuidString
            item.isEnabled = !store.busy && !hidden && store.configured
            if store.lastPresetID == preset.id { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh monitor status", action: #selector(refreshStatus), keyEquivalent: "r"); refresh.target = self; refresh.isEnabled = !store.busy; menu.addItem(refresh)
        let settings = NSMenuItem(title: "Configure OpenDDPM…", action: #selector(showWindow), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit OpenDDPM", action: #selector(quit), keyEquivalent: "q"); quit.target = self; quit.isEnabled = !store.busy; menu.addItem(quit)
        menu.autoenablesItems = false
        statusItem.menu = menu
    }
    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = store.configuration.presets.first(where: { $0.id.uuidString == id }) else { return }
        store.apply(preset)
    }
    @objc func refreshStatus() { store.refresh() }
    @objc func showWindow() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "OpenDDPM"
            created.minSize = NSSize(width: 920, height: 650)
            created.contentView = NSHostingView(rootView: ConfigurationView(store: store))
            created.appearance = NSAppearance(named: .darkAqua)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

@main
struct OpenDDPMApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterdisplaycli")
            do {
                let output = try HelperRunner(executable: helper).run(["get", "-identifiers", "-type=Display"])
                let monitors = try ConnectedMonitor.decode(output)
                print("Bundled helper OK. Found \(monitors.count) monitor(s).")
                for monitor in monitors { print("\(monitor.name): \(monitor.serial)") }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.run()
    }
}
