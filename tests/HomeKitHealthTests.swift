import Foundation

@main
struct HomeKitHealthTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.string(from: now)
        func report(_ time: String, running: Bool = true) -> HomeKitHealth {
            HomeKitHealth(running: running, connected: true, time: time)
        }
        precondition(report(fractional).isRunning(at: now))
        formatter.formatOptions = [.withInternetDateTime]
        precondition(report(formatter.string(from: now)).isRunning(at: now))
        precondition(!report(fractional).isRunning(at: now.addingTimeInterval(15)))
        precondition(!report(fractional).isRunning(at: now.addingTimeInterval(-10)))
        precondition(!report(fractional, running: false).isRunning(at: now))
        precondition(!report("invalid").isRunning(at: now))
        precondition(!report(fractional).isRunning(at: now.addingTimeInterval(2), since: now.addingTimeInterval(1)))
        precondition(report(fractional).isRunning(at: now, since: now.addingTimeInterval(-1)))
        let data = Data("{\"running\":true,\"connected\":false,\"time\":\"2027-01-15T08:00:00.000Z\",\"error\":\"offline\"}".utf8)
        let disconnected = try JSONDecoder().decode(HomeKitHealth.self, from: data)
        precondition(!disconnected.connected && disconnected.error == "offline")
        let stopped = try JSONDecoder().decode(HomeKitHealth.self, from: Data("{\"running\":false,\"connected\":false,\"time\":\"2027-01-15T08:00:00Z\"}".utf8))
        precondition(!stopped.isRunning(at: now) && stopped.error == nil)
        print("HomeKit health: 10 assertions passed")
    }
}
