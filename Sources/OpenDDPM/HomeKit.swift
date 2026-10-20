import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
final class HomeKitManager: ObservableObject {
    @Published var working = false
    @Published var message = "HomeKit service is not running"
    @Published var pin = ""
    @Published var televisionPaired = false
    @Published var scenesPaired = false
    @Published var running = false
    @Published var televisionImage: NSImage?
    @Published var scenesImage: NSImage?
    private var timer: Timer?
    private var setupError: String?
    private let directory = ControlPaths.directory.appendingPathComponent("homekit")
    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }
    func reload() {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("health.json")), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let timestamp = (row["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            running = row["running"] as? Bool == true && timestamp.map { Date().timeIntervalSince($0) < 15 } == true
            if !working && setupError == nil { message = running ? (row["connected"] as? Bool == true ? "Running · connected to OpenDDPM" : "Running · \(row["error"] as? String ?? "waiting for OpenDDPM")") : "HomeKit service is not running" }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.json")), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pin = row["pin"] as? String ?? ""
            televisionPaired = row["televisionPaired"] as? Bool ?? false
            scenesPaired = row["scenesPaired"] as? Bool ?? false
            televisionImage = NSImage(contentsOf: directory.appendingPathComponent("television.png"))
            scenesImage = NSImage(contentsOf: directory.appendingPathComponent("scenes.png"))
        }
    }
    func perform(_ action: String) {
        guard !working else { return }
        setupError = nil
        working = true; message = action == "stop" ? "Stopping HomeKit service…" : "Installing and starting HomeKit service…"
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
            working = false
            if let result { setupError = result; message = "HomeKit setup failed: \(result)" }
            else { reload() }
        }
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var homekit: HomeKitManager
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Apple Home & Shortcuts").font(.title.bold())
            Text("Home controls select complete presets through the same coordinator as this app.").foregroundStyle(.secondary)
            GroupBox("Apple Home") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(homekit.message).textSelection(.enabled)
                    Text("The local bridge requires Node.js 22, 24 or 26. Install & start downloads its pinned dependencies and enables launch at login.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Install & start") { homekit.perform("install") }.disabled(homekit.working || !store.configured)
                        Button("Stop") { homekit.perform("stop") }.disabled(homekit.working || !homekit.running)
                        if homekit.working { ProgressView().controlSize(.small) }
                    }
                    if homekit.running, !homekit.pin.isEmpty {
                        Text("On iPhone: Home → + → Add Accessory. Scan Monitor first; add Scenes for preset buttons in automations.").font(.callout)
                        HStack(alignment: .top, spacing: 18) {
                            pairing("Monitor", image: homekit.televisionImage, paired: homekit.televisionPaired)
                            pairing("Scenes", image: homekit.scenesImage, paired: homekit.scenesPaired)
                        }
                        Text(homekit.pin).font(.title3.monospaced()).textSelection(.enabled).privacySensitive()
                    }
                    Text("This Mac must be awake and retain its monitor control connection. A hidden video input may prevent switching back until an independent USB transport is available. Monitor power control is not included.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Apple Shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Right-click a preset in the remote → Copy Apple Shortcuts URL. In Shortcuts, add URL and Open URLs using the copied address. It launches OpenDDPM and selects that preset.")
                    Text("For scripts, use the app's --list-presets, --status, --apply ID --wait, --previous --wait and --remote commands. --wait reports verified, unverified, failed or superseded for that particular request.").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
        }
    }
    private func pairing(_ title: String, image: NSImage?, paired: Bool) -> some View {
        VStack(spacing: 7) {
            Text(title).font(.headline)
            if paired { Label("Paired", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else if let image { Image(nsImage: image).resizable().interpolation(.none).frame(width: 150, height: 150).privacySensitive() }
        }.frame(maxWidth: .infinity)
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
