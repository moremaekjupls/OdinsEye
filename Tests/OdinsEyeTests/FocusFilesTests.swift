import Foundation
import Testing
@testable import OdinsEye

@Suite struct FocusFilesTests {
    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    @Test func noAssertionsMeansNoFocus() {
        let json = #"{"data":[{"storeInvalidationRecords":[],"storeInvalidationRequestRecords":[]}]}"#
        #expect(FocusFiles.activeModeID(from: data(json)) == nil)
    }

    @Test func activeModeIsFoundInsideAssertionRecords() {
        let json = #"""
        {"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}],
        "storeInvalidationRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}
        """#
        #expect(FocusFiles.activeModeID(from: data(json)) == "com.apple.focus.work")
    }

    @Test func endedModeInInvalidationRecordsIsNotActive() {
        let json = #"""
        {"data":[{"storeAssertionRecords":[],
        "storeInvalidationRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}
        """#
        #expect(FocusFiles.activeModeID(from: data(json)) == nil)
    }

    @Test func garbageIsHarmless() {
        #expect(FocusFiles.activeModeID(from: data("not json")) == nil)
        #expect(FocusFiles.modes(from: data("[]")).isEmpty)
    }

    @Test func modesReadNameSymbolAndTint() throws {
        let json = #"""
        {"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"Работа","symbolImageName":"person.lanyardcard.fill","tintColorName":"systemTealColor"}}}}]}
        """#
        let mode = try #require(FocusFiles.modes(from: data(json))["com.apple.focus.work"])
        #expect(mode.name == "Работа" && mode.symbol == "person.lanyardcard.fill" && mode.tint == "systemTealColor")
    }
}
