import Foundation
import Testing
@testable import OdinsEye

@Suite struct SettingsProfileTests {
    @Test func oldProfileWithoutNewKeysDecodes() throws {
        let json = #"{"sounds":false,"glass":true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(SettingsSnapshot.self, from: json)
        #expect(!s.sounds && s.glass)
        #expect(s.openDelay == 0.05 && s.hiddenTabs == nil)
    }

    @Test func handEditedValuesAreClamped() throws {
        let json = #"{"glassTint":5,"openDelay":-3,"songColorStrength":0}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(SettingsSnapshot.self, from: json)
        #expect(s.glassTint == 0.9 && s.openDelay == 0 && s.songColorStrength == 0.1)
    }

    @Test func roundTripKeepsEverything() throws {
        var s = SettingsSnapshot()
        s.glass = true; s.glassTint = 0.4; s.hiddenTabs = ["clipboard"]; s.openDelay = 0.3
        let back = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func nilTabsMeansTabsDoNotCount() {
        var profile = SettingsSnapshot(); profile.hiddenTabs = nil
        var current = SettingsSnapshot(); current.hiddenTabs = ["currency", "snippets"]
        #expect(profile.matches(current: current))
        profile.hiddenTabs = ["currency"]
        #expect(!profile.matches(current: current))
        profile.hiddenTabs = ["snippets", "currency"]
        #expect(profile.matches(current: current))
    }

    @Test func sliderNoiseStillMatches() {
        var a = SettingsSnapshot(); a.glassTint = 0.6
        var b = a; b.glassTint = 0.6004
        #expect(a.matches(current: b))
        b.glassTint = 0.7
        #expect(!a.matches(current: b))
    }

    @Test func builtInProfilesAreDistinctAndStable() {
        let all = SettingsProfile.builtIn
        #expect(all.count == 4)
        #expect(Set(all.map(\.id)).count == 4)
        #expect(all.allSatisfy { $0.isBuiltIn })
        // Любые два готовых профиля отличаются, иначе «включён» мигал бы на обоих.
        for i in all.indices { for j in all.indices where i < j {
            #expect(!all[i].settings.matches(current: all[j].settings))
        } }
    }

    @Test func nextNameSkipsTaken() {
        let first = SettingsProfile.nextName(existing: [])
        let second = SettingsProfile.nextName(existing: [first])
        #expect(first != second)
    }
}
