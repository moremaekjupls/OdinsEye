import AppKit
import Testing
@testable import OdinsEye

@Suite struct PanelOptionsTests {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, count: Int = 256) -> [UInt8] {
        (0..<count).flatMap { _ in [r, g, b, 255] }
    }

    @Test func redArtworkGivesRed() throws {
        let color = try #require(ArtworkColor.dominant(ofRGBA: solid(220, 30, 30)))
        #expect(color.redComponent > 0.7 && color.greenComponent < 0.3)
    }

    @Test func blackWhiteAndGreyGiveNothing() {
        #expect(ArtworkColor.dominant(ofRGBA: solid(0, 0, 0)) == nil)
        #expect(ArtworkColor.dominant(ofRGBA: solid(255, 255, 255)) == nil)
        #expect(ArtworkColor.dominant(ofRGBA: solid(128, 128, 128)) == nil)
    }

    @Test func colourBeatsGreyBackground() throws {
        let pixels = solid(128, 128, 128, count: 200) + solid(30, 60, 220, count: 56)
        let color = try #require(ArtworkColor.dominant(ofRGBA: pixels))
        #expect(color.blueComponent > 0.7)
    }

    @Test func fullscreenMeansCoveringTheScreen() {
        let screen = CGSize(width: 1512, height: 982)
        #expect(FullscreenProbe.covers(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), screenSize: screen))
        // «Зелёная» кнопка оставляет строку меню.
        #expect(!FullscreenProbe.covers(bounds: CGRect(x: 0, y: 38, width: 1512, height: 944), screenSize: screen))
        #expect(!FullscreenProbe.covers(bounds: CGRect(x: 100, y: 100, width: 900, height: 600), screenSize: screen))
    }
}
