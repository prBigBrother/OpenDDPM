import Foundation

@main
struct CoreTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func expectError(_ message: String, _ block: () throws -> Void) {
        do { try block(); check(false, message) } catch { check(true, message) }
    }
    static func main() throws {
        let fixtures = """
        {"deviceType":"Display","alphanumericSerial":"DEMO01","name":"DELL U4025QW"},
        {"deviceType":"VirtualScreen","name":"Virtual"},
        {"deviceType":"Display","name":"No identifier"}
        """
        let discovered = try ConnectedMonitor.decode(fixtures)
        check(discovered.count == 1 && discovered[0].serial == "DEMO01", "Discovery filters virtual and unidentifiable displays")
        let empty = try ConnectedMonitor.decode("[]")
        check(empty.isEmpty, "Empty discovery")
        expectError("Malformed discovery fails") { _ = try ConnectedMonitor.decode("Failed.") }
        let invalid = DisplayPreset(name: "Bad", layout: .equal, main: .dp, secondary: .dp)
        expectError("Duplicate split sources rejected") { try invalid.validate() }
        expectError("Empty names rejected") { try DisplayPreset(name: "  ", layout: .full, main: .dp, secondary: .hdmi).validate() }
        for local in VideoInput.allCases {
            for main in VideoInput.allCases {
                for secondary in VideoInput.allCases where secondary != main {
                    for layout in SplitLayout.allCases {
                        let preset = DisplayPreset(name: "Test", layout: layout, main: main, secondary: secondary)
                        if !preset.includes(local) {
                            expectError("Visibility guard works for \(local)") { _ = try TransitionPlanner.plan(preset, currentMain: local, local: local, keepVisible: true) }
                            let plan = try TransitionPlanner.plan(preset, currentMain: local, local: local, keepVisible: false)
                            check(plan.last?.register == 0x60 && plan.last?.value == main.code, "Local input is removed only on the final write")
                        } else {
                            // Model Dell source swapping and assert the local input stays present.
                            for startingMain in VideoInput.allCases {
                                let startingSub = startingMain == local ? VideoInput.allCases.first { $0 != local }! : local
                                var actualMain = startingMain
                                var actualSub = startingSub
                                var actualMode = 0x24
                                let plan = try TransitionPlanner.plan(preset, currentMain: startingMain, local: local, keepVisible: true)
                                for action in plan {
                                    if action.register == 0xe9 { actualMode = action.value }
                                    if action.register == 0x60, let input = VideoInput(code: action.value) {
                                        if input == actualSub { let previous = actualMain; actualMain = input; actualSub = previous }
                                        else { actualMain = input }
                                    }
                                    if action.register == 0xe8, let input = VideoInput(code: action.value), input != actualMain { actualSub = input }
                                    check(actualMain == local || (actualMode != 0 && actualSub == local), "Planner preserves local visibility during every write")
                                }
                                check(actualMode == layout.code && actualMain == main && (actualMode == 0 || actualSub == secondary), "Planner reaches requested sources")
                            }
                        }
                    }
                }
            }
        }
        var configuration = AppConfiguration()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("openddpm-tests-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: path) }
        configuration.localInput = .thunderbolt
        try ConfigurationFile.save(configuration, to: path)
        let loaded = try ConfigurationFile.load(path)
        check(loaded.localInput == .thunderbolt && loaded.presets == configuration.presets, "Configuration persists across Macs without a hardcoded DP input")
        configuration.presets.append(configuration.presets[0])
        expectError("Duplicate preset identifiers rejected") { try configuration.validate() }
        configuration.schemaVersion = 10
        expectError("Unknown config schema rejected") { try configuration.validate() }
        check(VideoInput(code: 0x19) == .thunderbolt && VideoInput(code: 0x0f) == .dp, "Input register mappings")
        check(SplitLayout.largeLeft.code == 0x2a && SplitLayout.equal.code == 0x24, "U4025QW layout register mappings")
        print("PASS: \(count) core assertions")
    }
}
