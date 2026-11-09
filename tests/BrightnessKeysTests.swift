import AppKit

@MainActor
final class TestBrightnessListener: BrightnessKeyListening {
    var isActive = false
    var canStart = false
    var starts = 0
    func start(context: UnsafeMutableRawPointer) -> Bool {
        starts += 1; isActive = canStart; return isActive
    }
    func stop() { isActive = false }
    func resume() { isActive = canStart }
}

@MainActor
final class TestFunctionKeys: BrightnessFunctionKeyListening {
    var isActive = false
    var failure: String?
    var canStart = false
    var onPress: ((Double) -> Void)?
    func start(onPress: @escaping (Double) -> Void) { isActive = canStart; self.onPress = onPress }
    func stop() { isActive = false; onPress = nil }
}

@main
struct BrightnessKeysTests {
    @MainActor static func main() {
        let suite = "OpenDDPM.BrightnessKeysTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = TestBrightnessListener()
        let functions = TestFunctionKeys()
        var trusted = false
        var prompts = 0
        let controller = BrightnessKeyController(listener: listener, functionListener: functions, defaults: defaults,
                                                 isTrusted: { trusted }, requestTrust: { prompts += 1 })
        defer { controller.setEnabled(false) }

        // A stale negative AX result must not veto a functioning event tap.
        listener.canStart = true
        controller.setEnabled(true)
        precondition(controller.isEnabled && controller.issue == nil && prompts == 0)
        precondition(controller.statusText.contains("is active"))

        // Grant/revoke changes must reconcile without toggling the preference.
        listener.canStart = false; listener.isActive = false
        controller.refreshAccess()
        precondition(!controller.isEnabled && controller.requested && prompts == 0)
        listener.canStart = true
        controller.refreshAccess()
        precondition(controller.isEnabled && controller.issue == nil)

        // Only an explicit enable may request permission, never restore/retry.
        controller.setEnabled(false)
        listener.canStart = false
        controller.setEnabled(true)
        precondition(!controller.isEnabled && prompts == 1)
        controller.restore(); controller.refreshAccess()
        precondition(prompts == 1)
        trusted = true
        controller.refreshAccess()
        precondition(controller.issue?.contains("Accessibility is granted") == true)
        listener.canStart = true
        controller.refreshAccess()
        precondition(controller.isEnabled && controller.issue == nil)

        var steps = [Double]()
        var decisions = [String]()
        controller.canHandle = { true }
        controller.onStep = { steps.append($0) }
        controller.onDiagnostic = { decisions.append($0) }
        func keyboard(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            return event // Construct only; never post an event to the system.
        }
        precondition(controller.handle(type: .keyDown, event: keyboard(145)) == nil)
        precondition(steps == [-6.25] && decisions.last?.contains("keyboard") == true)
        precondition(controller.handle(type: .keyUp, event: keyboard(145, down: false)) == nil)
        precondition(steps.count == 1, "Key-up must not adjust brightness")
        precondition(controller.handle(type: .keyDown, event: keyboard(144, flags: [.maskAlternate, .maskShift])) == nil)
        precondition(steps.last == 1.5625, "Fine brightness must retain Option-Shift behavior")
        precondition(controller.handle(type: .keyDown, event: keyboard(145, flags: .maskCommand)) != nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(122)) != nil, "Ordinary F1 must remain untouched")
        precondition(steps.count == 2)
        controller.canHandle = { false }
        precondition(controller.handle(type: .keyDown, event: keyboard(145)) != nil)
        precondition(steps.count == 2 && decisions.last?.contains("unavailable") == true)
        controller.canHandle = { true }
        let media = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 8, data1: (3 << 16) | (0x0a << 8), data2: -1)!.cgEvent!
        precondition(controller.handle(type: CGEventType(rawValue: 14)!, event: media) == nil)
        precondition(steps.last == -6.25 && steps.count == 3 && decisions.last?.contains("system-defined") == true,
                     "System-defined brightness must remain supported alongside keyboard events")

        controller.setFunctionKeysEnabled(true)
        let beforeFunctionKeys = steps.count
        precondition(controller.handle(type: .keyDown, event: keyboard(122)) == nil)
        precondition(steps.last == -6.25 && steps.count == beforeFunctionKeys + 1)
        precondition(controller.handle(type: .keyUp, event: keyboard(122, down: false)) == nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(120)) == nil)
        precondition(steps.last == 6.25 && steps.count == beforeFunctionKeys + 2)
        precondition(controller.handle(type: .keyDown, event: keyboard(122, flags: .maskCommand)) != nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(122, flags: .maskControl)) != nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(122, flags: .maskAlternate)) != nil)
        precondition(steps.count == beforeFunctionKeys + 2, "F1/F2 compatibility must preserve system shortcuts")
        let restored = BrightnessKeyController(listener: TestBrightnessListener(), functionListener: TestFunctionKeys(), defaults: defaults)
        precondition(restored.functionKeysEnabled, "Keyboard compatibility must survive app restart")
        controller.setFunctionKeysEnabled(false)
        precondition(controller.handle(type: .keyDown, event: keyboard(122)) != nil)
        precondition(steps.count == beforeFunctionKeys + 2, "Disabling compatibility must restore ordinary F1")

        // Plain NuPhy brightness keys are F14/F15, not F1/F2. They remain
        // native brightness keys when the optional F1/F2 mapping is disabled.
        let beforeLegacy = steps.count
        let nuphyFlags = CGEventFlags(rawValue: 0x800100)
        precondition(!controller.functionKeysEnabled)
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: nuphyFlags)) == nil)
        precondition(steps.count == beforeLegacy + 1 && steps.last == -6.25)
        precondition(controller.handle(type: .keyUp, event: keyboard(107, down: false, flags: nuphyFlags)) == nil)
        precondition(steps.count == beforeLegacy + 1, "F14 key-up must not adjust brightness")
        precondition(controller.handle(type: .keyDown, event: keyboard(113, flags: nuphyFlags)) == nil)
        precondition(steps.count == beforeLegacy + 2 && steps.last == 6.25)
        precondition(controller.handle(type: .keyUp, event: keyboard(113, down: false, flags: nuphyFlags)) == nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(113, flags: [.maskSecondaryFn, .maskAlternate, .maskShift])) == nil)
        precondition(steps.count == beforeLegacy + 3 && steps.last == 1.5625)
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: [.maskSecondaryFn, .maskCommand])) != nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: [.maskSecondaryFn, .maskControl])) != nil)
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: [.maskSecondaryFn, .maskAlternate])) != nil)
        precondition(steps.count == beforeLegacy + 3)
        controller.canHandle = { false }
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: nuphyFlags)) != nil)
        precondition(steps.count == beforeLegacy + 3)
        controller.canHandle = { true }

        // Registered F1/F2 must bypass the tap and run exactly once via Carbon.
        functions.canStart = true
        controller.setFunctionKeysEnabled(true)
        // F1/F2 registration must not suppress the distinct legacy key pair.
        precondition(controller.handle(type: .keyDown, event: keyboard(107, flags: nuphyFlags)) == nil)
        precondition(steps.count == beforeLegacy + 4 && steps.last == -6.25)
        precondition(controller.handle(type: .keyUp, event: keyboard(107, down: false, flags: nuphyFlags)) == nil)
        let beforeRegistered = steps.count
        precondition(functions.isActive && controller.statusText.contains("system hotkeys registered"))
        precondition(controller.handle(type: .keyDown, event: keyboard(122)) != nil)
        precondition(steps.count == beforeRegistered)
        functions.onPress?(-6.25)
        precondition(steps.count == beforeRegistered + 1 && steps.last == -6.25)
        functions.onPress?(1.5625)
        precondition(steps.last == 1.5625)
        controller.canHandle = { false }
        functions.onPress?(-6.25)
        precondition(steps.count == beforeRegistered + 2)
        controller.setFunctionKeysEnabled(false)
        precondition(!functions.isActive)

        controller.setEnabled(false)
        let starts = listener.starts
        controller.refreshAccess(); controller.restore()
        precondition(!controller.requested && !controller.isEnabled && listener.starts == starts)
        print("PASS: media/virtual brightness and NuPhy F14/F15, fine steps; key-up, ordinary keys and unavailable controls preserved; stale AX trust cannot block a working listener; access changes reconcile; background checks never prompt; disabling stops retries")
    }
}
