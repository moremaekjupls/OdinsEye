import Foundation
import Testing
@testable import OdinsEye

/// Что карточка сессии знает о ходе: вопрос, шаги, файлы, ответ.
@MainActor
struct AgentTurnDetailsTests {
    private func store() -> AgentSessionStore {
        AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
    }

    private func feed(_ store: AgentSessionStore, _ json: String) {
        store.apply(AgentEvent.parse(Data(json.utf8))!)
    }

    @Test func parsesPromptReplyAndEditedFile() {
        let prompt = AgentEvent.parse(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"fix\nthe  bug"}"#.utf8))
        #expect(prompt?.prompt == "fix the  bug")
        let stop = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","last_assistant_message":"Done. All green."}"#.utf8))
        #expect(stop?.reply == "Done. All green.")
        let edit = AgentEvent.parse(Data(#"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Edit","tool_input":{"file_path":"/x/y/Invoice.swift"}}"#.utf8))
        #expect(edit?.file == "Invoice.swift")
        let read = AgentEvent.parse(Data(#"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Read","tool_input":{"file_path":"/x/y/Invoice.swift"}}"#.utf8))
        #expect(read?.file == nil)
    }

    @Test func longReplyIsClipped() {
        let long = String(repeating: "а", count: 5000)
        let stop = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","last_assistant_message":"\#(long)"}"#.utf8))
        #expect((stop?.reply?.count ?? 0) <= AgentEvent.maxMessage)
    }

    @Test func aTurnCollectsStepsFilesAndReply() {
        let s = store()
        feed(s, #"{"hook_event_name":"UserPromptSubmit","session_id":"a","cwd":"/p","prompt":"go"}"#)
        for n in 1...6 {
            feed(s, #"{"hook_event_name":"PreToolUse","session_id":"a","cwd":"/p","tool_name":"Edit","tool_input":{"file_path":"/p/F\#(n % 2).swift"}}"#)
        }
        #expect(s.sessions[0].steps.count == AgentSessionStore.maxSteps)
        #expect(s.sessions[0].files == ["F1.swift", "F0.swift"])
        feed(s, #"{"hook_event_name":"Stop","session_id":"a","cwd":"/p","last_assistant_message":"ok"}"#)
        #expect(s.sessions[0].reply == "ok")
        #expect(s.sessions[0].steps.count == AgentSessionStore.maxSteps)
    }

    @Test func aNewPromptStartsATurnFromScratch() {
        let s = store()
        feed(s, #"{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"one"}"#)
        feed(s, #"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Write","tool_input":{"file_path":"/p/A.swift"}}"#)
        feed(s, #"{"hook_event_name":"Stop","session_id":"a","last_assistant_message":"first"}"#)
        feed(s, #"{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"two"}"#)
        let session = s.sessions[0]
        #expect(session.prompt == "two")
        #expect(session.reply == nil)
        #expect(session.steps.isEmpty)
        #expect(session.files.isEmpty)
    }
}

@MainActor
struct TerminalJumpTests {
    @Test func parsesPidAndTtyAndRejectsOddTty() {
        let ok = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","odin_pid":4242,"odin_tty":"ttys003"}"#.utf8))
        #expect(ok?.pid == 4242 && ok?.tty == "ttys003")
        let dev = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","odin_tty":"/dev/ttys012"}"#.utf8))
        #expect(dev?.tty == "ttys012")
        let bad = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","odin_pid":1,"odin_tty":"ttys1\" & do shell script"}"#.utf8))
        #expect(bad?.tty == nil && bad?.pid == nil)
    }

    @Test func findsTheHostAppOfThisProcess() {
        // Тест идёт под xctest/swift-test: хозяин либо найден, либо нет, но без падения.
        _ = TerminalJumper.hostApp(ofPID: Int(getpid()))
        #expect(TerminalJumper.hostApp(ofPID: 0) == nil)
    }
}
