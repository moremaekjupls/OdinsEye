import Foundation

/// Unix-сокет, в который хуки Claude Code пишут JSON.
///
/// Слушает, а не опрашивает: в простое процесс спит в ядре. Одно соединение —
/// одно сообщение: прочитали, закрыли. Закрывать надо сразу, а не держать:
/// хук — это `nc -U`, и пока соединение открыто, он ждёт секунду (`-w1`), а
/// хуки Claude Code синхронные, то есть каждый вызов инструмента встал бы
/// на секунду. С закрытием `nc` уходит за ~10 мс.
///
/// Права: каталог 0700, сокет 0600 — писать может только тот же пользователь.
final class AgentSocketServer: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "odinseye.agents.accept", qos: .utility)
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1

    init(path: String) { self.path = path }

    /// `onMessage` вызывается с одним сообщением, на фоновой очереди.
    func start(onMessage: @escaping @Sendable (Data) -> Void) {
        queue.sync {
            guard source == nil else { return }
            guard let fd = Self.listen(on: path) else { return }
            descriptor = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [fd] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    DispatchQueue.global(qos: .utility).async {
                        if let data = Self.readMessage(from: client) { onMessage(data) }
                        close(client)
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
