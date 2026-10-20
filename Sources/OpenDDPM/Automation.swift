import Foundation
import Network
import AppKit
import Darwin

enum ControlPaths {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenDDPM")
    static let connection = directory.appendingPathComponent("control.json")
    static let port: UInt16 = 57571
}

struct ControlConnection: Codable {
    var port: UInt16
    var token: String
}

@MainActor
final class LocalControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "OpenDDPM.control")
    private var lockFD: Int32 = -1
    private let store: AppStore
    private var connection: ControlConnection?
    init(store: AppStore) { self.store = store }
    func start() throws {
        try FileManager.default.createDirectory(at: ControlPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = ControlPaths.directory.appendingPathComponent("application.lock")
        lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ControlError.message("OpenDDPM is already running. Use its preset remote.") }
        let descriptor: ControlConnection
        if let data = try? Data(contentsOf: ControlPaths.connection), let saved = try? JSONDecoder().decode(ControlConnection.self, from: data), saved.token.count >= 64 {
            descriptor = ControlConnection(port: ControlPaths.port, token: saved.token)
        } else {
            descriptor = ControlConnection(port: ControlPaths.port, token: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        connection = descriptor
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ControlPaths.port)!)
        let server = try NWListener(using: parameters)
        server.newConnectionHandler = { [weak self] client in
            let session = ControlHTTPSession(client: client) { request in
                guard let self else { return (503, ["error": "OpenDDPM unavailable"]) }
                return await self.handle(request)
            }
            session.start()
        }
        server.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor [weak self] in self?.store.error = "Local control could not start: \(error.localizedDescription)" } }
        }
        listener = server; server.start(queue: queue)
        try JSONEncoder().encode(descriptor).write(to: ControlPaths.connection, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ControlPaths.connection.path)
    }
    private func handle(_ request: HTTPRequest) -> (Int, Any) {
        guard let token = connection?.token, request.headers["authorization"] == "Bearer \(token)" else { return (401, ["error": "Unauthorized"]) }
        do {
            switch (request.method, request.path) {
            case ("GET", "/status"):
                return (200, ["state": try object(store.transition), "busy": store.busy, "configured": store.configured, "journalError": TransitionJournal.standard.lastError as Any? ?? NSNull()])
            case ("GET", "/presets"):
                return (200, store.configuration.presets.map { preset -> [String: Any] in
                    ["id": preset.id.uuidString, "name": preset.name, "detail": preset.detail, "layout": preset.layout.rawValue, "main": preset.main.rawValue, "secondary": preset.secondary.rawValue, "blocked": store.configuration.keepLocalVisible && !preset.includes(store.configuration.localInput)]
                })
            case ("POST", "/apply"):
                guard let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String], let key = body["preset"] else { return (400, ["error": "Expected a preset ID or unique name."]) }
                let matches = store.configuration.presets.filter { $0.id.uuidString.lowercased() == key.lowercased() || $0.name == key }
                guard matches.count == 1, let preset = matches.first else { return (400, ["error": "Preset missing or ambiguous. Use its UUID."]) }
                let id = try store.request(preset)
                return (202, ["requestID": id.uuidString, "presetID": preset.id.uuidString])
            case ("POST", "/previous"):
                guard let preset = store.previousPreset else { return (409, ["error": "No previous verified preset."]) }
                return (202, ["requestID": try store.request(preset).uuidString, "presetID": preset.id.uuidString])
            case ("POST", "/refresh"):
                let options = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Bool]
                store.refresh(quietly: options?["quiet"] == true)
                return (202, ["accepted": true])
            case ("POST", "/remote"): store.openRemote?(); return (200, ["opened": true])
            default:
                if request.method == "GET", request.path.hasPrefix("/requests/"), let id = UUID(uuidString: String(request.path.dropFirst(10))), let receipt = store.coordinator.receipts.first(where: { $0.id == id }) {
                    return (200, try object(receipt))
                }
                return (404, ["error": "Unknown command or expired request."])
            }
        } catch { return (400, ["error": error.localizedDescription]) }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
}

// All mutable session state is confined to its serial queue.
private final class ControlHTTPSession: @unchecked Sendable {
    let client: NWConnection
    let handler: (HTTPRequest) async -> (Int, Any)
    let queue = DispatchQueue(label: "OpenDDPM.http")
    var data = Data()
    var completed = false
    var timer: DispatchWorkItem?
    init(client: NWConnection, handler: @escaping (HTTPRequest) async -> (Int, Any)) { self.client = client; self.handler = handler }
    func start() {
        client.start(queue: queue)
        let timer = DispatchWorkItem { [weak self] in self?.client.cancel() }
        self.timer = timer; queue.asyncAfter(deadline: .now() + 5, execute: timer)
        receive()
    }
    func receive() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] chunk, _, ended, error in
            if let chunk { data.append(chunk) }
            do {
                if let request = try HTTPRequest.parse(data) {
                    guard !completed else { return }; completed = true
                    Task {
                        let (code, body) = await handler(request)
                        queue.async { self.reply(code, body) }
                    }
                } else if ended || error != nil { timer?.cancel(); client.cancel() }
                else { receive() }
            } catch { reply(400, ["error": error.localizedDescription]) }
        }
    }
    func reply(_ code: Int, _ object: Any) {
        timer?.cancel()
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        client.send(content: Data(header.utf8) + body, completion: .contentProcessed { [self] _ in client.cancel() })
    }
}

enum ControlCLI {
    static let commands = ["--list-presets", "--status", "--apply", "--previous", "--remote"]
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let command = args.dropFirst().first, commands.contains(command) else { return false }
        do {
            var result: Any
            switch command {
            case "--list-presets": result = try call("GET", "/presets")
            case "--status":
                _ = try call("POST", "/refresh")
                let until = Date().addingTimeInterval(12)
                repeat { result = try call("GET", "/status"); if (result as? [String: Any])?["busy"] as? Bool == false { break }; Thread.sleep(forTimeInterval: 0.15) } while Date() < until
            case "--apply":
                guard args.count >= 3, !args[2].hasPrefix("--") else { throw ControlError.message("Usage: OpenDDPM --apply PRESET_UUID_OR_NAME [--wait]") }
                result = try call("POST", "/apply", body: ["preset": args[2]])
            case "--previous": result = try call("POST", "/previous")
            default: result = try call("POST", "/remote")
            }
            if args.contains("--wait"), let id = (result as? [String: Any])?["requestID"] as? String {
                let until = Date().addingTimeInterval(30)
                repeat {
                    result = try call("GET", "/requests/\(id)")
                    if let phase = (result as? [String: Any])?["phase"] as? String, !["queued", "applying"].contains(phase) {
                        printJSON(result)
                        exit(phase == "verified" ? 0 : phase == "unverified" ? 3 : phase == "superseded" ? 4 : 1)
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                } while Date() < until
                throw ControlError.message("Timed out waiting for request. Inspect --status or the transition journal.")
            }
            printJSON(result); exit(0)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func printJSON(_ value: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    }
    static func call(_ method: String, _ path: String, body: [String: String]? = nil) throws -> Any {
        guard let data = try? Data(contentsOf: ControlPaths.connection), let descriptor = try? JSONDecoder().decode(ControlConnection.self, from: data) else { throw ControlError.message("OpenDDPM is not ready. Open the app first.") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(descriptor.port)\(path)")!)
        request.httpMethod = method; request.timeoutInterval = 4
        request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let semaphore = DispatchSemaphore(value: 0)
        var received: Data?; var response: URLResponse?; var failure: Error?
        URLSession.shared.dataTask(with: request) { data, reply, error in received = data; response = reply; failure = error; semaphore.signal() }.resume()
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw ControlError.message("Local control did not respond.") }
        if let failure { throw failure }
        guard let received else { throw ControlError.message("Empty local-control response.") }
        let object = try JSONSerialization.jsonObject(with: received)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ControlError.message((object as? [String: String])?["error"] ?? "Local control failed.") }
        return object
    }
}
