import Foundation

// Node's ISO timestamps include fractional seconds; older reports may omit them.
struct HomeKitHealth: Decodable {
    let running: Bool
    let connected: Bool
    let time: String
    var error: String?

    func isRunning(at now: Date = Date(), since startedAt: Date? = nil) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: time)
        formatter.formatOptions = [.withInternetDateTime]
        guard running, let timestamp = fractional ?? formatter.date(from: time) else { return false }
        if let startedAt, timestamp < startedAt { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= -5 && age < 15
    }
}
