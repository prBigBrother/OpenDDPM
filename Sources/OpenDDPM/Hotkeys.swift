import AppKit
import Carbon
import SwiftUI

@MainActor
final class HotkeyManager {
    var onPress: ((UUID) -> Void)?
    private var handler: EventHandlerRef?
    private var handlerStatus: OSStatus = noErr
    private var registrations: [EventHotKeyRef] = []
    private var identifiers: [UInt32: UUID] = [:]
    init() {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4f444450 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            let value = identifier.id
            DispatchQueue.main.async { if let preset = manager.identifiers[value] { manager.onPress?(preset) } }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func synchronize(_ presets: [DisplayPreset]) -> [UUID: String] {
        for registration in registrations { UnregisterEventHotKey(registration) }
        registrations.removeAll(); identifiers.removeAll()
        var failures: [UUID: String] = [:]
        for (index, preset) in presets.enumerated() {
            guard let shortcut = preset.shortcut else { continue }
            guard handlerStatus == noErr else { failures[preset.id] = "Hotkey listener could not start (\(handlerStatus)). Restart OpenDDPM."; continue }
            let identifier = UInt32(index + 1)
            var registration: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4f444450, id: identifier), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &registration)
            if result == noErr, let registration { registrations.append(registration); identifiers[identifier] = preset.id }
            else { failures[preset.id] = "Unavailable: another app or macOS may reserve this combination (\(result))." }
        }
        return failures
    }
}

final class ShortcutButton: NSButton {
    var capture: ((PresetShortcut) -> Void)?
    var shortcut: PresetShortcut?
    var recording = false
    var recordingChanged: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; target = self; action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func beginRecording() { recording = true; recordingChanged?(true); title = "Press keys…"; window?.makeFirstResponder(self) }
    func updateTitle() { title = shortcut?.display ?? "Record…" }
    override func resignFirstResponder() -> Bool { if recording { recording = false; recordingChanged?(false) }; updateTitle(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { record(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { if recording { record(event) } else { super.keyDown(with: event) } }
    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { recording = false; updateTitle(); recordingChanged?(false); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= PresetShortcut.command }
        if flags.contains(.shift) { modifiers |= PresetShortcut.shift }
        if flags.contains(.option) { modifiers |= PresetShortcut.option }
        if flags.contains(.control) { modifiers |= PresetShortcut.control }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers ?? "Key \(event.keyCode)"
        let value = PresetShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        recording = false; updateTitle(); capture?(value); recordingChanged?(false)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var preset: DisplayPreset
    var capture: (PresetShortcut) -> Void
    var recordingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> ShortcutButton { ShortcutButton(frame: .zero) }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.shortcut = preset.shortcut; button.capture = capture
        button.recordingChanged = recordingChanged
        if !button.recording { button.updateTitle() }
        button.setAccessibilityLabel("Record hotkey for \(preset.name)")
        button.setAccessibilityIdentifier("shortcut-\(preset.id.uuidString)")
    }
}
