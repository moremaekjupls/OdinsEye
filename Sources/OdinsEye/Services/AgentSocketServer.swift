import Foundation

/// Ответ, который сервер может дать хуку: соединение остаётся открытым, пока
/// кто-то не решит. Закрывается ровно один раз — ответом, пустым закрытием или
/// по таймеру; всё остальное после этого ничего не делает.
final class AgentReply: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private var finished = false
    private var handlers: [@Sendable () -> Void] = []

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Вызывается один раз, когда соединение закрыто — любым способом. Если оно
    /// уже закрыто, вызывается сразу.
    func whenFinished(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }

    /// Закрыть, если ещё не закрыто, через `seconds`.
    func expire(after seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in send(nil) }
    }

    /// Записать ответ (или ничего) и закрыть. `nc` у хука печатает полученное
    /// в stdout, а пустое закрытие для Claude Code значит «решения нет».
    func send(_ data: Data?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let toRun = handlers
        handlers = []
        lock.unlock()

        if let data {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
        close(fd)
        toRun.forEach { $0() }
    }
}

/// Unix-сокет, в который хуки Claude Code пишут JSON.
///
/// Слушает, а не опрашивает: в простое процесс спит в ядре. Одно соединение —
/// одно сообщение: прочитали, закрыли. Закрывать надо сразу, а не держать:
/// хук — это `nc -U`, и пока соединение открыто, он ждёт секунду (`-w1`), а
/// хуки Claude Code синхронные, то есть каждый вызов инструмента встал бы
/// на секунду. С закрытием `nc` уходит за ~10 мс.
///
/// Исключение — сообщения, на которые ждут ответ (`expectsReply`): запрос
/// разрешения. Для них соединение отдаётся наружу как `AgentReply` и живёт,
/// пока человек не нажмёт кнопку. `nc` после конца ввода закрывает свою
/// сторону записи, но продолжает ждать и печатает всё, что пришло, — поэтому
/// конец потока на стороне сервера не означает, что хук умер.
///
/// Права: каталог 0700, сокет 0600 — писать может только тот же пользователь.
final class AgentSocketServer: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "odinseye.agents.accept", qos: .utility)
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1

    private let heldLock = NSLock()
    private var held: [ObjectIdentifier: AgentReply] = [:]

    init(path: String) { self.path = path }

    /// `onMessage` вызывается с одним сообщением, на фоновой очереди. Ответ
    /// непустой только для сообщений, на которые `expectsReply` сказал «да».
    func start(
        expectsReply: @escaping @Sendable (Data) -> Bool = { _ in false },
        onMessage: @escaping @Sendable (Data, AgentReply?) -> Void
    ) {
        queue.sync {
            guard source == nil else { return }
            guard let fd = Self.listen(on: path) else { return }
            descriptor = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [fd, weak self] in
                let server = self
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    DispatchQueue.global(qos: .utility).async {
                        guard let data = Self.readMessage(from: client) else { close(client); return }
                        if expectsReply(data) {
                            let reply = AgentReply(fd: client)
                            server?.keep(reply)
                            onMessage(data, reply)
                        } else {
                            // Сначала передать, потом закрыть: хук уходит в
                            // момент закрытия, и следующий его собрат не
                            // должен обогнать этот в очереди главного потока.
                            onMessage(data, nil)
                            close(client)
                        }
                    }
                }
            }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            descriptor = -1
            unlink(path)
        }
        // Хук, ждущий ответа, не должен висеть из-за выключенной вкладки.
        heldLock.lock()
        let open = Array(held.values)
        held = [:]
        heldLock.unlock()
        open.forEach { $0.send(nil) }
    }

    private func keep(_ reply: AgentReply) {
        let id = ObjectIdentifier(reply)
        heldLock.lock(); held[id] = reply; heldLock.unlock()
        reply.whenFinished { [weak self] in
            self?.heldLock.lock(); self?.held[id] = nil; self?.heldLock.unlock()
        }
    }

    // MARK: - POSIX

    private static func listen(on path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }

        // Каталог доступен только владельцу; на случай, если он уже был.
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(folder, 0o700)

        // Остаток прошлого запуска: bind на существующий файл падает.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.withCString { strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        guard Foundation.listen(fd, 16) == 0 else { close(fd); unlink(path); return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Читает, пока не получится целый JSON, не придёт перевод строки, не
    /// кончится соединение или время (1 с). Лишнего не ждёт: `nc` может не
    /// закрыть свою сторону после EOF на stdin.
    private static func readMessage(from client: Int32) -> Data? {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= AgentEvent.maxBytes {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if data.last == 0x0A { break }
            if (try? JSONSerialization.jsonObject(with: data)) != nil { break }
        }
        return data.isEmpty ? nil : data
    }
}
