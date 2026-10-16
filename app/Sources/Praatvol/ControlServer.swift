import Darwin
import Foundation
import PraatvolCore

// All mutable transport state belongs to queue; only Sendable values cross its boundary.
final class ControlServer: @unchecked Sendable {
    typealias Completion = @Sendable (Result<ControlStatus, ControlError>) -> Void
    typealias Handler = @Sendable (ControlRequest.Command, @escaping Completion) -> Void

    private final class Connection: @unchecked Sendable {
        let descriptor: Int32
        let reader: DispatchSourceRead
        var writer: DispatchSourceWrite?
        var framer = ControlLineFramer()
        var pending = Data()
        var handled = false
        var subscribed = false
        var closing = false
        var readerSuspended = false
        init(descriptor: Int32, reader: DispatchSourceRead) {
            self.descriptor = descriptor
            self.reader = reader
        }
    }

    private struct Reply: Encodable {
        let ok: Bool
        let status: ControlStatus?
        let error: String?
        let message: String?
    }

    private let queue = DispatchQueue(label: "praatvol.control")
    private let socketURL: URL
    private let handler: Handler
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var snapshot = ControlStatus(step: .idle)
    private var lastPushedSnapshot: ControlStatus?
    private var ownsSocket = false

    init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            do { try self.listen() } catch {
                AppLog.shared.event("control-listen-failed", code: (error as NSError).code)
                self.cleanup()
            }
        }
    }

    func stop() { queue.sync { cleanup() } }

    func update(_ status: ControlStatus) { queue.async { self.snapshot = status } }

    func publish(_ status: ControlStatus, force: Bool = false) {
        queue.async {
            self.snapshot = status
            if !force, status == self.lastPushedSnapshot { return }
            self.lastPushedSnapshot = status
            for connection in Array(self.connections.values) where connection.subscribed {
                self.send(status, to: connection)
            }
        }
    }

    private func listen() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw socketError() }
        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EEXIST) }
            guard unlink(socketURL.path) == 0 else { throw socketError() }
        } else if errno != ENOENT {
            throw socketError()
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError() }
        do {
            try configure(descriptor)
            try bindSocket(descriptor)
            ownsSocket = true
            guard chmod(socketURL.path, 0o600) == 0 else { throw socketError() }
            guard Darwin.listen(descriptor, 8) == 0 else { throw socketError() }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(descriptor) }
        source.setCancelHandler { Darwin.close(descriptor) }
        listener = source
        source.resume()
    }

    private func bindSocket(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path.map { UInt8(bitPattern: $0) })
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw socketError() }
    }

    private func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw socketError() }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw socketError() }
    }

    private func acceptConnections(_ descriptor: Int32) {
        while true {
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                if errno == EINTR { continue }
                if errno != EAGAIN { AppLog.shared.event("control-accept-failed", code: Int(errno)) }
                return
            }
            guard connections.count < 8 else {
                Darwin.close(accepted)
                continue
            }
            do { try configure(accepted) } catch {
                AppLog.shared.event("control-configure-failed", code: (error as NSError).code)
                Darwin.close(accepted)
                continue
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
            let connection = Connection(descriptor: accepted, reader: reader)
            connections[accepted] = connection
            reader.setEventHandler { [weak self, weak connection] in
                if let connection { self?.read(connection) }
            }
            reader.setCancelHandler { Darwin.close(accepted) }
            reader.resume()
            var user: uid_t = 0
            var group: gid_t = 0
            if getpeereid(accepted, &user, &group) != 0 {
                AppLog.shared.event("control-peer-failed", code: Int(errno))
                disconnect(connection)
            } else if user != getuid() {
                AppLog.shared.event("control-peer-denied")
                connection.handled = true
                reply(.failure(.denied), to: connection)
            }
        }
    }

    private func read(_ connection: Connection) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(connection.descriptor, &bytes, bytes.count)
        if count == 0 {
            // A client may half-close its request; let an outstanding reply drain first.
            if shouldDisconnectAtEndOfInput(connection) {
                disconnect(connection)
            } else if !connection.readerSuspended {
                connection.reader.suspend()
                connection.readerSuspended = true
            }
            return
        }
        guard count > 0 else {
            if errno == EINTR || errno == EAGAIN { return }
            AppLog.shared.event("control-read-failed", code: Int(errno))
            disconnect(connection)
            return
        }
        do {
            let lines = try connection.framer.append(Data(bytes.prefix(count)))
            guard !connection.handled else { return }
            guard let line = lines.first else { return }
            connection.handled = true
            do { dispatch(try ControlRequest.decode(line), connection: connection) } catch {
                AppLog.shared.event("control-request-invalid")
                reply(.failure(.badRequest), to: connection)
            }
        } catch {
            AppLog.shared.event("control-line-too-long")
            disconnect(connection)
        }
    }

    private func shouldDisconnectAtEndOfInput(_ connection: Connection) -> Bool {
        connection.subscribed || !connection.handled
    }

    private func dispatch(_ request: ControlRequest, connection: Connection) {
        AppLog.shared.event("control-command \(request.cmd.rawValue)")
        switch request.cmd {
        case .status: reply(.success(snapshot), to: connection)
        case .subscribe:
            connection.subscribed = true
            send(snapshot, to: connection)
        case .recordRoom, .recordCall, .stop, .transcribe, .keep:
            handler(request.cmd) { [weak self, weak connection] response in
                guard let self else { return }
                self.queue.async {
                    guard let connection, self.connections[connection.descriptor] === connection else { return }
                    self.reply(response, to: connection)
                }
            }
        }
    }

    private func reply(_ response: Result<ControlStatus, ControlError>, to connection: Connection) {
        connection.closing = true
        switch response {
        case .success(let status):
            send(Reply(ok: true, status: status, error: nil, message: nil), to: connection)
        case .failure(let error):
            let message: String
            if error == .notReviewing {
                message =
                    error.message
                    + " Transcribe only applies to audio awaiting review. Empty recordings require a new recording."
            } else {
                message = error.message
            }
            send(Reply(ok: false, status: nil, error: error.rawValue, message: message), to: connection)
        }
    }

    private func send<Value: Encodable>(_ value: Value, to connection: Connection) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let line = try encoder.encode(value) + Data([10])
            guard connection.pending.count + line.count <= 16_384 else {
                AppLog.shared.event("control-slow-client")
                disconnect(connection)
                return
            }
            connection.pending.append(line)
            flush(connection)
        } catch {
            AppLog.shared.event("control-encode-failed", code: (error as NSError).code)
            disconnect(connection)
        }
    }

    private func flush(_ connection: Connection) {
        while !connection.pending.isEmpty {
            let count = connection.pending.withUnsafeBytes {
                Darwin.write(connection.descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                connection.pending.removeFirst(count)
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                waitForWrite(connection)
                return
            }
            AppLog.shared.event("control-write-failed", code: Int(errno))
            disconnect(connection)
            return
        }
        connection.writer?.cancel()
        connection.writer = nil
        if connection.closing { disconnect(connection) }
    }

    private func waitForWrite(_ connection: Connection) {
        guard connection.writer == nil else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: connection.descriptor, queue: queue)
        writer.setEventHandler { [weak self, weak connection] in
            if let connection { self?.flush(connection) }
        }
        connection.writer = writer
        writer.resume()
    }

    private func disconnect(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.descriptor) != nil else { return }
        connection.writer?.cancel()
        connection.writer = nil
        if connection.readerSuspended { connection.reader.resume() }
        connection.reader.cancel()
    }

    private func cleanup() {
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) { disconnect(connection) }
        if ownsSocket {
            if unlink(socketURL.path) != 0 { AppLog.shared.event("control-unlink-failed", code: Int(errno)) }
            ownsSocket = false
        }
    }

    private func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
