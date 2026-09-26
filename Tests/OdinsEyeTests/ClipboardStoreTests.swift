import Foundation
import Testing
@testable import OdinsEye

/// История буфера: без лимита, закреплённые сверху и переживают «Очистить»,
/// всё переживает перезапуск. Каждый тест пишет в свою временную папку —
/// настоящий `clipboard.json` не трогается.
@MainActor
struct ClipboardStoreTests {
    private static func file() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("odinseye-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("clipboard.json")
    }

    private static func text(_ string: String) -> ClipItem {
        ClipItem(payload: .text(string), date: Date())
    }

    private static func texts(_ store: ClipboardStore) -> [String] {
        store.items.map(\.preview)
    }

    @Test func keepsMoreThanTheOldLimit() throws {
        let store = ClipboardStore(file: try Self.file())
        for index in 0..<150 { store.record(Self.text("entry \(index)")) }
        #expect(store.items.count == 150)
        #expect(store.items.first?.preview == "entry 149")
    }

    @Test func copyingAgainMovesToTopWithoutDuplicate() throws {
        let store = ClipboardStore(file: try Self.file())
        store.record(Self.text("a"))
        store.record(Self.text("b"))
        store.record(Self.text("a"))
        #expect(Self.texts(store) == ["a", "b"])
    }

    @Test func pinnedStayOnTopOfNewCopies() throws {
        let store = ClipboardStore(file: try Self.file())
        store.record(Self.text("keeper"))
        store.record(Self.text("b"))
        store.togglePin(store.items[1])
        store.record(Self.text("c"))
        #expect(Self.texts(store) == ["keeper", "c", "b"])
        #expect(store.items[0].isPinned)
    }

    @Test func recopyingPinnedKeepsThePin() throws {
        let store = ClipboardStore(file: try Self.file())
        store.record(Self.text("keeper"))
        store.togglePin(store.items[0])
        store.record(Self.text("b"))
        store.record(Self.text("keeper"))
        #expect(Self.texts(store) == ["keeper", "b"])
        #expect(store.items[0].isPinned)
    }

    @Test func clearLeavesPinned() throws {
        let store = ClipboardStore(file: try Self.file())
        store.record(Self.text("a"))
        store.record(Self.text("keeper"))
        store.togglePin(store.items[0])
        store.record(Self.text("b"))
        store.clear()
        #expect(Self.texts(store) == ["keeper"])
        #expect(!store.hasUnpinned)
    }

    @Test func unpinGoesBackAmongTheRest() throws {
        let store = ClipboardStore(file: try Self.file())
        store.record(Self.text("a"))
        store.record(Self.text("b"))
        store.togglePin(store.items[1])
        #expect(Self.texts(store) == ["a", "b"])
        store.togglePin(store.items[0])
        #expect(Self.texts(store) == ["a", "b"])
        #expect(store.items.allSatisfy { !$0.isPinned })
    }

    @Test func historySurvivesRelaunch() throws {
        let file = try Self.file()
        let first = ClipboardStore(file: file)
        first.record(ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/report.pdf")), date: Date()))
        first.record(Self.text("hello"))
        first.record(Self.text("keeper"))
        first.togglePin(first.items[0])
        first.flush()

        let second = ClipboardStore(file: file)
        #expect(Self.texts(second) == ["keeper", "hello", "report.pdf"])
        #expect(second.items[0].isPinned)
        #expect(second.items[2].payload == .file(URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    @Test func historyFileIsPrivate() throws {
        let file = try Self.file()
        let store = ClipboardStore(file: file)
        store.record(Self.text("secret-ish"))
        store.flush()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
