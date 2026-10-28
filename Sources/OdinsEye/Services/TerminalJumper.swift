import AppKit
import Darwin

/// Окно, в котором идёт сессия Claude Code: терминал или приложение Claude.
///
/// Хук присылает pid процесса Claude Code. От него вверх по родителям
/// ищется первое обычное приложение: оно и есть хозяин сессии. Ничего не
/// читается с экрана, список окон не нужен.
enum TerminalJumper {
    /// Приложение, в котором запущена сессия, или `nil`, если процесс ушёл.
    static func hostApp(ofPID pid: Int) -> NSRunningApplication? {
        var current = pid_t(pid)
        for _ in 0..<32 {
            guard current > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    static func hostName(of session: AgentSession) -> String? {
        session.pid.flatMap(hostApp(ofPID:))?.localizedName
    }

    /// Выводит окно сессии вперёд. В Terminal.app выбирает ещё и нужную
    /// вкладку по tty; для остальных приложений достаточно активации.
    @MainActor
    @discardableResult
    static func jump(to session: AgentSession) -> Bool {
        guard let pid = session.pid, let app = hostApp(ofPID: pid) else { return false }
        if app.bundleIdentifier == "com.apple.Terminal", let tty = session.tty, selectTerminalTab(tty: tty) { return true }
        return app.activate()
    }

    /// `tty` проверен при разборе события: `ttysNNN`, больше ничего.
    @MainActor
    private static func selectTerminalTab(tty: String) -> Bool {
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
