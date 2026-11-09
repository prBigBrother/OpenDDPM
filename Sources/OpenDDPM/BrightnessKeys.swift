import AppKit
import ApplicationServices
import Combine
import Carbon

@MainActor
protocol BrightnessKeyListening: AnyObject {
    var isActive: Bool { get }
    var locationDescription: String { get }
    func start(context: UnsafeMutableRawPointer) -> Bool
    func stop()
    func resume()
}

extension BrightnessKeyListening {
    var locationDescription: String { "event tap" }
}

@MainActor
protocol BrightnessFunctionKeyListening: AnyObject {
    var isActive: Bool { get }
    var failure: String? { get }
    func start(onPress: @escaping (Double) -> Void)
    func stop()
}

/// WindowServer owns these registrations; ordinary F1/F2 do not depend on a
/// CGEvent tap receiving keyboard events. Media keys still use the event tap.
@MainActor
private final class SystemBrightnessFunctionKeys: BrightnessFunctionKeyListening {
    private var handler: EventHandlerRef?
    private var registrations = [EventHotKeyRef]()
    private var steps = [UInt32: Double]()
    private var onPress: ((Double) -> Void)?
    private(set) var failure: String?
    var isActive: Bool { registrations.count == 6 }
    deinit {
        for registration in registrations { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }
    func start(onPress: @escaping (Double) -> Void) {
        guard !isActive else { return }
        stop(); self.onPress = onPress; failure = nil
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4f44424b else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<SystemBrightnessFunctionKeys>.fromOpaque(context).takeUnretainedValue()
                if let step = owner.steps[identifier.id] { owner.onPress?(step) }
                return noErr
            }
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { failure = "F1/F2 handler failed (\(result))."; stop(); return }
        for (modifiers, amount) in [(UInt32(0), 6.25), (UInt32(shiftKey), 6.25), (UInt32(optionKey | shiftKey), 1.5625)] {
            for (code, direction) in [(UInt32(122), -1.0), (UInt32(120), 1.0)] {
                let id = UInt32(steps.count + 1)
                var registration: EventHotKeyRef?
                let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x4f44424b, id: id),
                                                 GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &registration)
                guard status == noErr, let registration else {
                    failure = "F1/F2 registration failed (\(status)); another app may reserve these keys."
                    stop(); return
                }
                registrations.append(registration); steps[id] = direction * amount
            }
        }
    }
    func stop() {
        for registration in registrations { UnregisterEventHotKey(registration) }
        registrations.removeAll(); steps.removeAll(); onPress = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

@MainActor
private final class SystemBrightnessKeyListener: BrightnessKeyListening {
    private var taps = [(port: CFMachPort, source: CFRunLoopSource)]()
    private(set) var locationDescription = "not started"
    var isActive: Bool { !taps.isEmpty && taps.allSatisfy { CFMachPortIsValid($0.port) && CGEvent.tapIsEnabled(tap: $0.port) } }
    deinit {
        for tap in taps {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            CFMachPortInvalidate(tap.port)
        }
    }
    func start(context: UnsafeMutableRawPointer) -> Bool {
        stop()
        let mask = (CGEventMask(1) << 14)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<BrightnessKeyController>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
            }
        }
        var locations = [String]()
        // Physical HID events and events injected below HID need both routes.
        // Returning nil for a handled event prevents a second session delivery.
        for (location, label) in [(CGEventTapLocation.cghidEventTap, "HID"), (.cgSessionEventTap, "session")] {
            guard let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: context) else { continue }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port); continue
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            taps.append((port, source)); locations.append(label)
        }
        locationDescription = locations.joined(separator: " + ")
        guard isActive else { stop(); return false }
        return true
    }
    func resume() { for tap in taps { CGEvent.tapEnable(tap: tap.port, enable: true) } }
    func stop() {
        for tap in taps {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            CGEvent.tapEnable(tap: tap.port, enable: false); CFMachPortInvalidate(tap.port)
        }
        taps.removeAll()
    }
}

/// The actual event tap, rather than a potentially stale AX trust query, is
/// authoritative for whether brightness keys can be intercepted.
@MainActor
final class BrightnessKeyController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var issue: String?
    @Published private(set) var functionKeysEnabled: Bool
    var canHandle: (() -> Bool)?
    var onStep: ((Double) -> Void)?
    // Reports brightness-related keys and aggregate stream health, never typing.
    var onDiagnostic: ((String) -> Void)?
    private var consumedKeys = Set<Int>()
    private var observedInput = false
    private let preference = "OpenDDPM.brightnessKeys"
    private static let functionKeyPreference = "OpenDDPM.brightnessFunctionKeys"
    private let listener: BrightnessKeyListening
    private let functionListener: BrightnessFunctionKeyListening
    private let defaults: UserDefaults
    private let isTrusted: () -> Bool
    private let requestTrust: () -> Void
    private var retryTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(listener: BrightnessKeyListening? = nil, functionListener: BrightnessFunctionKeyListening? = nil, defaults: UserDefaults = .standard,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestTrust: @escaping () -> Void = {
             _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         }) {
        self.listener = listener ?? SystemBrightnessKeyListener()
        self.functionListener = functionListener ?? SystemBrightnessFunctionKeys()
        self.defaults = defaults; self.isTrusted = isTrusted; self.requestTrust = requestTrust
        self.functionKeysEnabled = defaults.bool(forKey: Self.functionKeyPreference)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccess() }
        }
    }
    deinit {
        retryTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
    var requested: Bool { defaults.bool(forKey: preference) }
    var statusText: String {
        guard requested else { return "Brightness keys are off." }
        let function = functionListener.isActive ? "F1/F2 system hotkeys registered. " : ""
        return function + (listener.isActive ? "Brightness key listener is active (\(listener.locationDescription))." : "Media key listener is not active; checking access automatically.")
    }
    private func synchronizeFunctionKeys() {
        guard requested && functionKeysEnabled else { functionListener.stop(); return }
        guard !functionListener.isActive else { return }
        functionListener.start { [weak self] step in self?.handleFunctionHotkey(step) }
        onDiagnostic?(functionListener.isActive ? "F1/F2 system hotkeys registered" : functionListener.failure ?? "F1/F2 registration failed")
    }
    func handleFunctionHotkey(_ step: Double) {
        guard requested, functionKeysEnabled, functionListener.isActive, canHandle?() == true, onStep != nil else {
            onDiagnostic?("F1/F2 system hotkey: control unavailable"); return
        }
        onDiagnostic?("F1/F2 system hotkey: accepted")
        onStep?(step)
    }

    func setFunctionKeysEnabled(_ enabled: Bool) {
        functionKeysEnabled = enabled
        defaults.set(enabled, forKey: Self.functionKeyPreference)
        synchronizeFunctionKeys()
    }
    func restore() {
        guard requested else { return }
        startMonitoring()
        refreshAccess()
    }
    func setEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        stop()
        defaults.set(enabled, forKey: preference)
        issue = nil
        guard enabled else { return }
        startMonitoring()
        refreshAccess()
        // Request only after an actual tap failure and only on an explicit opt-in.
        if !isEnabled && requestPermission && !isTrusted() { requestTrust() }
    }
    private func startMonitoring() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccess() }
        }
    }
    func refreshAccess() {
        guard requested else { return }
        synchronizeFunctionKeys()
        if listener.isActive { isEnabled = true; issue = functionListener.failure; return }
        consumedKeys.removeAll()
        let active = listener.start(context: Unmanaged.passUnretained(self).toOpaque())
        isEnabled = active || functionListener.isActive
        if active { issue = functionListener.failure }
        else if isTrusted() {
            issue = "Accessibility is granted, but macOS could not start the brightness key listener. OpenDDPM will retry automatically."
        } else {
            issue = "The brightness key listener could not start. If OpenDDPM is already enabled in system privacy settings, its running access status may be stale. OpenDDPM will retry automatically."
        }
    }
    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        listener.stop(); functionListener.stop(); consumedKeys.removeAll(); isEnabled = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            listener.resume()
            isEnabled = listener.isActive
            if !isEnabled { refreshAccess() }
            consumedKeys.removeAll()
            return Unmanaged.passUnretained(event)
        }
        if !observedInput, type == .keyDown || type.rawValue == 14 {
            observedInput = true
            onDiagnostic?("input stream received events")
        }
        let key: Int
        let isDown: Bool
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(.deviceIndependentFlagsMask)
        let source: String
        if type == .keyDown || type == .keyUp {
            // Apple brightness keys can arrive as ordinary keyboard events,
            // particularly with external/forwarded keyboards (virtual 144/145).
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 144 || code == 145 {
                key = code == 144 ? 2 : 3
            } else if code == 107 || code == 113 {
                // Legacy macOS brightness keys: NuPhy sends F14/F15 for plain
                // brightness presses and F1/F2 when its Fn key is held.
                key = code == 113 ? 2 : 3
            } else if code == 122 || code == 120 {
                // Do not consume or adjust here when WindowServer will deliver
                // the registered hotkey; otherwise a press could run twice.
                if functionListener.isActive { return Unmanaged.passUnretained(event) }
                guard functionKeysEnabled else {
                    if type == .keyDown { onDiagnostic?("regular F\(code == 122 ? 1 : 2): not a brightness event") }
                    return Unmanaged.passUnretained(event)
                }
                key = code == 120 ? 2 : 3
            } else {
                return Unmanaged.passUnretained(event)
            }
            isDown = type == .keyDown
            source = "keyboard"
        } else {
            guard type.rawValue == 14, let keyEvent = NSEvent(cgEvent: event), keyEvent.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            key = (keyEvent.data1 >> 16) & 0xffff
            guard key == 2 || key == 3 else {
                if key == 21 || key == 22 { onDiagnostic?("keyboard backlight key: not display brightness") }
                return Unmanaged.passUnretained(event)
            }
            let state = (keyEvent.data1 >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return Unmanaged.passUnretained(event) }
            isDown = state == 0x0a
            source = "system-defined"
        }
        if !isDown {
            return consumedKeys.remove(key) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard canHandle?() == true, onStep != nil else {
            onDiagnostic?("\(source) key \(key): control unavailable")
            return Unmanaged.passUnretained(event)
        }
        // Leave macOS shortcuts (Option opens Displays, Control changes focus) intact.
        let fine = flags.contains(.option) && flags.contains(.shift)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) || fine else {
            onDiagnostic?("\(source) key \(key): system shortcut passed through")
            return Unmanaged.passUnretained(event)
        }
        consumedKeys.insert(key)
        onDiagnostic?("\(source) key \(key): accepted")
        // Each down event, including hardware repeats, advances exactly one step.
        onStep?((key == 2 ? 1.0 : -1.0) * (fine ? 1.5625 : 6.25))
        return nil
    }
}
