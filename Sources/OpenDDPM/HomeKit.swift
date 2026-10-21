import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
final class HomeKitManager: ObservableObject {
    @Published var working = false
    @Published var message = "Apple Home is off"
    @Published var enabled = false
    @Published var connected = false
    @Published var connectionError: String?
    @Published var setupError: String?
    @Published var pin = ""
    @Published var televisionPaired = false
    @Published var scenesPaired = false
    @Published var scenesEnabled = true
    @Published var running = false
    @Published var televisionImage: NSImage?
    @Published var scenesImage: NSImage?
    private var timer: Timer?
    private let directory = ControlPaths.directory.appendingPathComponent("homekit")
    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.reload() } }
    }
    func reload() {
        let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.prbigbrother.OpenDDPM.homekit.plist")
        enabled = FileManager.default.fileExists(atPath: agent.path)
        let health = readHealth()
        running = health?.isRunning() == true
        connected = running && health?.connected == true
        connectionError = running && !connected ? health?.error : nil
        if !working && setupError == nil {
            message = connected ? "Ready for Apple Home" : running ? "Waiting for OpenDDPM" : enabled ? "Apple Home needs attention" : "Apple Home is off"
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.json")), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pin = row["pin"] as? String ?? ""
            televisionPaired = row["televisionPaired"] as? Bool ?? false
            scenesPaired = row["scenesPaired"] as? Bool ?? false
            scenesEnabled = row["scenesEnabled"] as? Bool ?? true
            televisionImage = NSImage(contentsOf: directory.appendingPathComponent("television.png"))
            scenesImage = NSImage(contentsOf: directory.appendingPathComponent("scenes.png"))
        } else {
            pin = ""; televisionPaired = false; scenesPaired = false
            televisionImage = nil; scenesImage = nil
        }
    }
    private func readHealth() -> HomeKitHealth? {
        (try? Data(contentsOf: directory.appendingPathComponent("health.json")))
            .flatMap { try? JSONDecoder().decode(HomeKitHealth.self, from: $0) }
    }
    func perform(_ action: String) {
        guard !working else { return }
        setupError = nil
        let restarting = enabled || running
        working = true
        message = action == "stop" ? "Disconnecting Apple Home…" : restarting ? "Restarting connection…" : "Connecting Apple Home…"
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HomeKit/install.mjs").path
        Task {
            let result = await Task.detached { () -> String? in
                guard let node = NodeRuntime.find() else { return "Install Node.js 22, 24 or 26, then retry." }
                let process = Process(); process.executableURL = node
                process.arguments = [script, action]
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    if process.terminationStatus == 0 { return nil }
                    return String(decoding: data.suffix(4000), as: UTF8.self)
                } catch { return error.localizedDescription }
            }.value
            if let result {
                setupError = result
                message = "Couldn’t update Apple Home"
            } else if action != "stop" {
                // launchctl returning only confirms launch, not that the bridge is ready.
                // Wait for a connected heartbeat from after launch, ignoring the old process.
                let launchedAt = Date()
                message = "Waiting for Apple Home…"
                var ready = false
                for _ in 0..<30 {
                    reload()
                    if let health = readHealth(), health.connected && health.isRunning(since: launchedAt) {
                        ready = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !ready {
                    setupError = "Apple Home did not confirm its connection within 30 seconds. Try again or check the service files."
                    message = "Couldn’t connect to Apple Home"
                }
            }
            working = false
            reload()
        }
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var homekit: HomeKitManager
    @ViewState private var copiedPin = false
    @ViewState private var advancedExpanded = false

    private var statusColor: Color {
        homekit.working ? accent : homekit.setupError != nil ? errorColor : homekit.connected ? accent : homekit.enabled ? warningColor : .secondary
    }

    var body: some View {
        Form {
            Section("Connection") {
                HStack(spacing: 14) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(homekit.message).font(.headline)
                        Text(homekit.working ? "Please wait. Your Home pairing is preserved." : homekit.televisionPaired ? (homekit.connected ? "Monitor is paired. Choose a preset from its input list in Home." : "Monitor is paired. Restore the connection to control it from Home.") : "Enable Apple Home, then add Monitor using the QR code below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if homekit.working { ProgressView().controlSize(.small) }
                    Toggle("Enable Apple Home", isOn: Binding(get: { homekit.enabled }, set: { homekit.perform($0 ? "start" : "stop") }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Enable Apple Home")
                        .disabled(homekit.working || (!homekit.enabled && !store.configured))
                }
                if !store.configured {
                    Text("Finish Monitor & inputs setup to enable Apple Home.").font(.callout).foregroundStyle(warningColor)
                }
                if !homekit.working && (homekit.setupError != nil || (homekit.enabled && !homekit.running)) {
                    HStack {
                        Text("The connection could not be started. Try again, or check Advanced below.").font(.callout).foregroundStyle(warningColor)
                        Spacer()
                        Button("Try again") { homekit.perform("start") }.disabled(homekit.working || !store.configured)
                    }
                }
                Text("New presets and changes to existing presets appear in Monitor’s input list automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if homekit.running && !homekit.televisionPaired {
                Section("Add Monitor to Home") {
                    Text("On your iPhone, open Home → + → Add Accessory and scan this code.")
                    pairing("Monitor", image: homekit.televisionImage, paired: false)
                    if !homekit.pin.isEmpty { pairingCode }
                    Text("Once added, open Monitor in Home and select an input to apply a preset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Keep your monitor available") {
                Text("Keep this Mac awake and connected to the monitor. Presets that hide this Mac may interrupt control until its input is visible again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Apple Home uses a local background service that starts when you sign in. Setup requires Node.js 22, 24 or 26 and downloads its dependencies on first use.")
                        if !homekit.working, let error = homekit.setupError ?? homekit.connectionError {
                            Text(error).font(.caption.monospaced()).foregroundStyle(errorColor)
                        }
                        HStack {
                            Button("Restart connection") { homekit.perform("start") }
                                .disabled(homekit.working || !homekit.enabled || !store.configured)
                            Button("Show service files") {
                                NSWorkspace.shared.open(ControlPaths.directory.appendingPathComponent("homekit"))
                            }
                        }
                        if homekit.televisionImage != nil || !homekit.pin.isEmpty {
                            Divider()
                            Text("Monitor setup code").font(.headline)
                            pairing("Monitor", image: homekit.televisionImage, paired: homekit.televisionPaired, showCode: true)
                            if !homekit.pin.isEmpty { pairingCode }
                            if homekit.televisionPaired {
                                Text("Monitor is already added to Home. To share access, invite someone to your home in the Home app.")
                                    .font(.caption)
                            }
                        }
                        if homekit.running && homekit.scenesEnabled {
                            Divider()
                            Text("Legacy Scenes accessory").font(.headline)
                            Text("Monitor already includes every preset. The separate Scenes accessory is optional.")
                            pairing("Scenes", image: homekit.scenesImage, paired: homekit.scenesPaired)
                            if !homekit.scenesPaired && !homekit.pin.isEmpty { pairingCode }
                        }
                        Text("Power control (On / Standby) and preset selection are supported in Apple Home.")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 12)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { homekit.reload() }
    }

    private var pairingCode: some View {
        HStack(spacing: 10) {
            Text(homekit.pin).font(.title3.monospaced().bold()).privacySensitive()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(homekit.pin, forType: .string)
                copiedPin = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPin = false }
            } label: {
                Label(copiedPin ? "Copied" : "Copy code", systemImage: copiedPin ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private func pairing(_ title: String, image: NSImage?, paired: Bool, showCode: Bool = false) -> some View {
        HStack(spacing: 16) {
            if paired {
                Label("\(title) is paired", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
            }
            if !paired || showCode {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.none).frame(width: 150, height: 150).privacySensitive()
                } else {
                    Label("Preparing pairing code…", systemImage: "qrcode").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ShortcutSetupView: View {
    let preset: DisplayPreset
    @Environment(\.dismiss) private var dismiss
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Use in Shortcuts", systemImage: "square.stack.3d.up").font(.title2.bold())
            Text(preset.name).font(.headline)
            Text("1. Copy the preset link below.\n2. In Shortcuts, create a shortcut and add the Open URLs action.\n3. Paste the link into that action and name your shortcut.")
                .lineSpacing(6)
            Text("The link keeps working when you rename or edit this preset.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Link copied" : "Copy preset link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("openddpm://apply?id=\(preset.id.uuidString)", forType: .string)
                    copied = true
                }
                Button("Open Shortcuts") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 510)
    }
}

// Locate an existing supported runtime without changing the user's shell or Node default.
enum NodeRuntime {
    static func find() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node")]
        for (directory, suffix) in [(".fnm/node-versions", "installation/bin/node"), (".local/share/fnm/node-versions", "installation/bin/node"), (".nvm/versions/node", "bin/node")] {
            let root = home.appendingPathComponent(directory)
            for entry in ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path > $1.path }) { candidates.append(entry.appendingPathComponent(suffix)) }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            let process = Process(); process.executableURL = candidate; process.arguments = ["--version"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let major = Int(version.dropFirst().split(separator: ".").first ?? "")
                if process.terminationStatus == 0, [22, 24, 26].contains(major ?? 0) { return candidate.resolvingSymlinksInPath() }
            } catch { continue }
        }
        return nil
    }
}
