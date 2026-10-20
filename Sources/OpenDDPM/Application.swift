import AppKit
import SwiftUI
import Combine

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var remote: NSPanel?
    var contextMenu: NSMenu?
    var controlServer: LocalControlServer?
    var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let server = LocalControlServer(store: store)
        do { try server.start(); controlServer = server }
        catch { fputs("\(error.localizedDescription)\n", stderr); NSApp.terminate(nil); return }
        let mainMenu = NSMenu()
        let appEntry = NSMenuItem(title: "OpenDDPM", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "OpenDDPM")
        let configure = NSMenuItem(title: "Configure OpenDDPM…", action: #selector(showWindow), keyEquivalent: ",")
        configure.target = self; appMenu.addItem(configure)
        let presetsMenu = NSMenuItem(title: "Show presets menu", action: #selector(showPresetsMenu), keyEquivalent: "p")
        presetsMenu.target = self; appMenu.addItem(presetsMenu)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit OpenDDPM", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        appEntry.submenu = appMenu; mainMenu.addItem(appEntry)
        let fileEntry = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileEntry.submenu = fileMenu; mainMenu.addItem(fileEntry)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "OpenDDPM")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "OpenDDPM · Monitor presets"
        store.openWindow = { [weak self] in self?.showWindow() }
        store.openRemote = { [weak self] in self?.showRemote() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateMenu() } }.store(in: &subscriptions)
        updateMenu()
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPresetsMenu() }
        }
        if !store.configured || CommandLine.arguments.contains("--show-window") { showWindow() }
        store.refresh()
        if CommandLine.arguments.contains("--show-remote") { showRemote() }
    }
    func updateMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "OpenDDPM", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        let state = NSMenuItem(title: store.busy ? store.progress : (store.status?.description ?? (store.configured ? "Refresh monitor status…" : "Configure monitor & inputs…")), action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        for preset in store.configuration.presets {
            let hidden = store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)
            let item = NSMenuItem(title: preset.name + "  ·  " + preset.detail + (preset.shortcut.map { "  \($0.display)" } ?? "") + (hidden ? "  🔒" : ""), action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = preset.id.uuidString
            item.isEnabled = !hidden && store.configured
            if store.lastPresetID == preset.id { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh monitor status", action: #selector(refreshStatus), keyEquivalent: "r"); refresh.target = self; refresh.isEnabled = !store.busy; menu.addItem(refresh)
        let settings = NSMenuItem(title: "Configure OpenDDPM…", action: #selector(showWindow), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit OpenDDPM", action: #selector(quit), keyEquivalent: "q"); quit.target = self; quit.isEnabled = !store.busy; menu.addItem(quit)
        menu.autoenablesItems = false
        contextMenu = menu
    }
    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = store.configuration.presets.first(where: { $0.id.uuidString == id }) else { return }
        store.apply(preset)
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showPresetsMenu() }
        else if remote?.isVisible == true { remote?.orderOut(nil) }
        else { showRemote() }
    }
    @objc func showRemote() {
        if remote == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 620), styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
            panel.title = "OpenDDPM · Preset remote"
            panel.minSize = NSSize(width: 420, height: 400)
            panel.contentView = NSHostingView(rootView: PresetRemoteView(store: store))
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.level = .floating; panel.center(); remote = panel
        }
        NSApp.activate(ignoringOtherApps: true); remote?.makeKeyAndOrderFront(nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "openddpm" {
            if url.host == "remote" { showRemote() }
            else if url.host == "previous" { store.previous() }
            else if url.host == "apply", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                    let preset = store.configuration.presets.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) { store.apply(preset) }
        }
    }
    @objc func refreshStatus() { store.refresh() }
    @objc func showPresetsMenu() {
        guard let menu = contextMenu else { return }
        if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }
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
    @objc func quit() {
        guard !store.busy else { NSSound.beep(); return }
        NSApp.terminate(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if store.configured { showRemote() } else { showWindow() }; return true }
}

@main
struct OpenDDPMApplication {
    @MainActor static func main() {
        if ControlCLI.runIfRequested() { return }
        if CommandLine.arguments.contains("--diagnose") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openddpm-ddc")
            do {
                let output = try HelperRunner(executable: helper).run(["list"])
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
