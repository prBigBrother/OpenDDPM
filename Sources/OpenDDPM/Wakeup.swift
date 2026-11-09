import Foundation

struct WakeConfiguration: Codable {
    var enabled = false
    var endpoint = "http://192.168.100.228"
    // Store BLE identity addresses, never transient connection slots.
    var inputs: [String: String] = [:]
    var deviceNames: [String: String]? = nil
}

struct WakeStatus: Decodable {
    struct Device: Decodable {
        var slot: Int
        var generation: UInt32
        var address: String
        var ready: Bool
        var name: String? = nil
    }
    struct Bond: Decodable {
        var address: String
        var name: String?
    }
    var bonds: [Bond]? = nil
    func name(for address: String) -> String {
        let device = devices.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        let bond = bonds?.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        for name in [device?.name, bond?.name] {
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        }
        return "Unnamed Mac"
    }
    var devices: [Device]
    var paired: [String]
    var wake_busy: Bool
}

struct WakeClient {
    var session: URLSession = .shared
    func request(_ configuration: WakeConfiguration, path: String, method: String = "GET") async throws -> Data {
        guard let base = URLComponents(string: configuration.endpoint),
              ["http", "https"].contains(base.scheme ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let url = URL(string: configuration.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
        else { throw ControlError.message("Enter the ESP32 HTTP address in Setup.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ControlError.message("ESP32 rejected the wake request. Refresh its device list and try again.")
        }
        return data
    }
    func status(_ configuration: WakeConfiguration) async throws -> WakeStatus {
        try JSONDecoder().decode(WakeStatus.self, from: await request(configuration, path: "/api/status"))
    }
    func wake(_ preset: DisplayPreset, configuration: WakeConfiguration, isEnabled: @escaping @Sendable () async -> Bool = { true }) async throws {
        guard configuration.enabled else { return }
        let addresses = Set(VideoInput.allCases.filter { preset.includes($0) }
            .compactMap { configuration.inputs[$0.rawValue] }.filter { !$0.isEmpty }.map { $0.uppercased() })
        guard !addresses.isEmpty else { return }
        var failures: [String] = []
        for address in addresses.sorted() {
            guard await isEnabled(), !Task.isCancelled else { return }
            do {
                var snapshot = try await status(configuration)
                let deadline = Date().addingTimeInterval(5)
                while snapshot.wake_busy && Date() < deadline {
                    guard await isEnabled(), !Task.isCancelled else { return }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    snapshot = try await status(configuration)
                }
                guard !snapshot.wake_busy else { throw ControlError.message("ESP32 is busy") }
                guard let device = snapshot.devices.first(where: { $0.address.uppercased() == address && $0.ready }) else {
                    throw ControlError.message("\(snapshot.name(for: address)) is not ready for Bluetooth wake")
                }
                guard await isEnabled(), !Task.isCancelled else { return }
                _ = try await request(configuration, path: "/api/wake?id=\(device.slot)&generation=\(device.generation)", method: "POST")
                // Firmware serializes five Shift taps. Give the accepted command time to finish
                // before submitting another target; never retry an ambiguous POST.
                if addresses.count > 1 { try await Task.sleep(nanoseconds: 3_000_000_000) }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw ControlError.message(failures.joined(separator: "; ")) }
    }
}
