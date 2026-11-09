import Foundation

final class WakeProtocol: URLProtocol {
    static var posts: [String] = []
    static var ready = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        if request.httpMethod == "POST" {
            Self.posts.append(url.query ?? "")
            body = "{}"
        } else {
            body = "{\"paired\":[\"AA\",\"BB\"],\"wake_busy\":false,\"devices\":[{\"slot\":1,\"generation\":987,\"address\":\"AA\",\"ready\":\(Self.ready)},{\"slot\":0,\"generation\":654,\"address\":\"BB\",\"ready\":true}]}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: request.httpMethod == "POST" ? 202 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct WakeTests {
    static func main() async throws {
        let old = try JSONEncoder().encode(AppConfiguration())
        var object = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        object.removeValue(forKey: "wakeup")
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(legacy.wakeup == nil, "Old configurations remain readable")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WakeProtocol.self]
        let client = WakeClient(session: URLSession(configuration: config))
        var wake = WakeConfiguration(enabled: true, inputs: ["dp": "aa", "thunderbolt": "BB"])
        var preset = DisplayPreset(name: "Test", layout: .full, main: .dp, secondary: .thunderbolt)
        try await client.wake(preset, configuration: wake)
        precondition(WakeProtocol.posts == ["id=1&generation=987"], "Use selected identity and fresh slot/generation")
        WakeProtocol.posts = []
        preset.layout = .equal
        wake.inputs["thunderbolt"] = "AA"
        try await client.wake(preset, configuration: wake)
        precondition(WakeProtocol.posts.count == 1, "Deduplicate identities")
        WakeProtocol.posts = []
        WakeProtocol.ready = false
        do { try await client.wake(preset, configuration: wake); fatalError("Offline target accepted") } catch {}
        precondition(WakeProtocol.posts.isEmpty, "Never wake another Mac as fallback")
        WakeProtocol.ready = true
        wake.inputs["thunderbolt"] = "BB"
        try await client.wake(preset, configuration: wake)
        precondition(Set(WakeProtocol.posts) == ["id=1&generation=987", "id=0&generation=654"], "Split wakes both targets")
        WakeProtocol.posts = []
        wake.enabled = false
        try await client.wake(preset, configuration: wake)
        precondition(WakeProtocol.posts.isEmpty, "Disabled integration never sends wake commands")
        wake.enabled = true
        try await client.wake(preset, configuration: wake, isEnabled: { false })
        precondition(WakeProtocol.posts.isEmpty, "Live global switch stops pending targets")
        let named = try JSONDecoder().decode(WakeStatus.self, from: Data("{\"paired\":[\"AA\"],\"wake_busy\":false,\"devices\":[],\"bonds\":[{\"address\":\"AA\",\"name\":\"MacBook Pro\"}]}".utf8))
        precondition(named.name(for: "aa") == "MacBook Pro", "Saved bond name is available when disconnected")
        precondition(named.name(for: "BB") == "Unnamed Mac", "Unknown names do not expose addresses")
        print("PASS: names, global disable, wake identity routing, split targets, deduplication, offline protection and legacy configuration")
    }
}
