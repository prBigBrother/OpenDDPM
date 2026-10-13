import Foundation

struct PresetShortcut: Codable, Equatable {
    // Carbon modifier constants remain stable; keep this model independent of AppKit.
    static let command: UInt32 = 256
    static let shift: UInt32 = 512
    static let option: UInt32 = 2048
    static let control: UInt32 = 4096
    static let allowed = command | shift | option | control
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    var identity: String { "\(keyCode):\(modifiers)" }
    var display: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "") +
        (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "") + keyLabel.uppercased()
    }
    func validate() throws {
        guard keyCode < 128, ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode),
              modifiers & ~Self.allowed == 0, modifiers & (Self.command | Self.option | Self.control) != 0,
              !keyLabel.isEmpty, keyLabel.count < 30 else {
            throw ControlError.message("Use a key with Command, Control, or Option. Escape cancels recording.")
        }
        if modifiers == Self.command && [12, 13, 35, 43].contains(keyCode) {
            throw ControlError.message("This shortcut is used by OpenDDPM. Add Control or Option, or choose another key.")
        }
    }
}
