import Testing
@testable import OdinsEye

/// Когда живым обоям играть. Окна и плеер проверяются глазами, здесь только
/// правило: оно решает, сколько обои стоят батареи.
struct WallpaperPolicyTests {
    private func ready() -> WallpaperPolicy {
        WallpaperPolicy(enabled: true, hasVideo: true)
    }

    @Test func playsWhenEnabledWithVideoOnPower() {
        #expect(ready().shouldPlay)
        #expect(ready().showsWindows)
    }

    @Test func neverPlaysWithoutSwitchOrVideo() {
        #expect(!WallpaperPolicy(enabled: false, hasVideo: true).shouldPlay)
        #expect(!WallpaperPolicy(enabled: true, hasVideo: false).shouldPlay)
        #expect(!WallpaperPolicy(enabled: false, hasVideo: true).showsWindows)
        #expect(!WallpaperPolicy(enabled: true, hasVideo: false).showsWindows)
    }

    @Test func pausesOnBatteryOnlyWhenAsked() {
        var policy = ready()
        policy.onBattery = true
        #expect(!policy.shouldPlay)
        policy.pauseOnBattery = false
        #expect(policy.shouldPlay)
        // Сеть: пауза на батарее ничего не значит.
        policy.onBattery = false
        policy.pauseOnBattery = true
        #expect(policy.shouldPlay)
    }

    @Test func pausesForSleepSessionCoverAndLowPower() {
        for change in [
            { (p: inout WallpaperPolicy) in p.screensAsleep = true },
            { (p: inout WallpaperPolicy) in p.sessionInactive = true },
            { (p: inout WallpaperPolicy) in p.covered = true },
            { (p: inout WallpaperPolicy) in p.lowPowerMode = true },
        ] {
            var policy = ready()
            change(&policy)
            #expect(!policy.shouldPlay)
            // Окна остаются: на паузе виден последний кадр.
            #expect(policy.showsWindows)
        }
    }

    @Test func lowPowerWinsOverBatterySetting() {
        var policy = ready()
        policy.pauseOnBattery = false
        policy.lowPowerMode = true
        #expect(!policy.shouldPlay)
    }
}
