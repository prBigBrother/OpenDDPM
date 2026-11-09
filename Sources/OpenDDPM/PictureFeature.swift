import Foundation

struct PictureFeature: Identifiable {
    var id: Int { register }
    let register: Int
    let title: String
    let range: ClosedRange<Int>?
    let choices: [(value: Int, title: String)]
    func accepts(_ value: Int) -> Bool {
        if register == 0x66 { return (0...65534).contains(value) && [1, 2].contains(value & 3) && ((value >> 6) & 3) < 3 }
        return range?.contains(value) ?? choices.contains { $0.value == value }
    }
    static let brightness = Self(register: 0x10, title: "Brightness", range: 0...100, choices: [])
    static let contrast = Self(register: 0x12, title: "Contrast", range: 0...100, choices: [])
    static let volume = Self(register: 0x62, title: "Speaker volume", range: 0...100, choices: [])
    static let automatic = Self(register: 0x66, title: "Automatic brightness", range: nil, choices: [])
    static let color = Self(register: 0xE2, title: "Color preset", range: nil, choices: [
        (0x00, "Standard"), (0x02, "Movie"), (0x04, "Game"), (0x0C, "5000K"),
        (0x0D, "5700K"), (0x0F, "6500K"), (0x10, "7500K"), (0x11, "9300K"),
        (0x13, "10000K"), (0x0B, "sRGB"), (0x1A, "BT.709"), (0x1B, "DCI-P3"),
        (0xA1, "Display P3"), (0x14, "Custom Color")])
    static func colorCommand(_ identifier: Int) -> (register: Int, value: Int)? {
        switch identifier {
        case 0x00: return (0xDC, 0x00)
        case 0x02: return (0xDC, 0x03)
        case 0x04: return (0xDC, 0x05)
        case 0x0C: return (0x14, 0x04)
        case 0x0D: return (0x14, 0x0B)
        case 0x0F: return (0x14, 0x05)
        case 0x10: return (0x14, 0x06)
        case 0x11: return (0x14, 0x08)
        case 0x13: return (0x14, 0x09)
        case 0x0B: return (0x14, 0x01)
        case 0x1A: return (0xF0, 0x09)
        case 0x1B: return (0xF0, 0x0A)
        case 0xA1: return (0xF0, 0xA1)
        case 0x14: return (0x14, 0x0C)
        default: return nil
        }
    }
    static var all: [Self] { [brightness, automatic, contrast, color, volume] }
}
