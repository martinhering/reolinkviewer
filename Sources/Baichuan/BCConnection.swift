import Foundation
import Network

/// One TCP connection to a camera. Frames packets, applies the codec, and routes replies to
/// subscriptions (by message number) or handlers (by message id, for camera-initiated messages).
public actor BCConnection {
    public typealias Handler = @Sendable (BCMessage) -> BCMessage?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "baichuan.connection")
    private var connection: NWConnection?
    private var codec: BCCodec
    private var subscriptions: [UInt16: BCSubscription] = [:]
    private var handlers: [UInt32: Handler] = [:]
    private var receiveTask: Task<Void, Never>?
    private var nextNum: UInt16 = 0
    private var closeError: Error?
    public var log: (@Sendable (String) -> Void)?

    public private(set) var packetsReceived = 0
    public private(set) var lastReceiveTime: Date?

    public var encryption: BCEncryption { codec.encryption }
    public var isOpen: Bool { connection != nil && closeError == nil }

    public init(host: String, port: UInt16, password: String) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 9000
        self.codec = BCCodec(password: password)
    }

    // MARK: Lifecycle

    public func connect(timeout: TimeInterval = 5) async throws {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        connection = conn
        closeError = nil
        let hostDescription = "\(host):\(port)"
        do {
            try await withTimeout(timeout) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = ResumeOnce(cont)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(nil)
                        case .failed(let e):
                            once.resume(BCError.connectionFailed("\(hostDescription): \(e.localizedDescription)"))
                        case .waiting(let e):
                            // No route / refused. NWConnection would retry forever; we don't.
                            once.resume(BCError.connectionFailed("\(hostDescription): \(e.localizedDescription)"))
                        case .cancelled:
                            once.resume(BCError.connectionClosed)
                        default:
                            break
                        }
                    }
                    conn.start(queue: self.queue)
                }
            }
        } catch {
            conn.cancel()
            connection = nil
            throw error
        }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e):
                Task { await self?.fail(BCError.connectionFailed(e.localizedDescription)) }
            case .cancelled:
                Task { await self?.fail(BCError.connectionClosed) }
            default:
                break
            }
        }
        receiveTask = Task { await self.receiveLoop() }
    }

    public func close() {
        fail(BCError.connectionClosed)
    }

    private func fail(_ error: Error) {
        guard closeError == nil else { return }
        closeError = error
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        let subs = subscriptions
        subscriptions = [:]
        handlers = [:]
        Task {
            for s in subs.values { await s.finish(error) }
        }
    }

    // MARK: Messaging

    public func nextMessageNumber() -> UInt16 {
        defer { nextNum &+= 1 }
        return nextNum
    }

    public func subscribe(_ msgNum: UInt16) -> BCSubscription {
        let s = BCSubscription(msgNum: msgNum)
        subscriptions[msgNum] = s
        return s
    }

    public func unsubscribe(_ msgNum: UInt16) {
        if let s = subscriptions.removeValue(forKey: msgNum) {
            Task { await s.finish(BCError.connectionClosed) }
        }
    }

    /// Installs a responder for messages the camera initiates (e.g. keep-alive).
    public func setHandler(msgId: UInt32, _ handler: Handler?) {
        handlers[msgId] = handler
    }

    public func send(_ m: BCMessage) async throws {
        if let e = closeError { throw e }
        guard let conn = connection else { throw BCError.notConnected }
        let data = codec.encode(m)
        log?("→ id=\(m.msgId) num=\(m.msgNum) class=\(String(m.msgClass, radix: 16)) code=\(m.responseCode) bytes=\(data.count)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: BCError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: Receiving

    private func read(_ n: Int) async throws -> Data {
        guard let conn = connection else { throw closeError ?? BCError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: BCError.connectionFailed(error.localizedDescription))
                } else if let data, data.count == n {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: BCError.connectionClosed)
                }
            }
        }
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                var header = try BCHeader.decodeBase(try await read(BCHeader.baseLength))
                if BCHeader.classHasPayloadOffset(header.msgClass) {
                    header.payloadOffset = try await read(4).le32(at: 0)
                }
                let body = header.bodyLength > 0 ? try await read(Int(header.bodyLength)) : Data()
                let message = try codec.decode(header: header, body: body)
                packetsReceived += 1
                lastReceiveTime = Date()
                await dispatch(message)
            }
        } catch {
            if !Task.isCancelled {
                log?("receive loop ended: \(error)")
                fail(error)
            }
        }
    }

    private func dispatch(_ m: BCMessage) async {
        if m.msgId != BCMsgID.video || m.binary == nil {
            log?("← id=\(m.msgId) num=\(m.msgNum) class=\(String(m.msgClass, radix: 16)) code=\(m.responseCode) ext=\(m.extensionXML?.count ?? 0) xml=\(m.xml?.count ?? 0) bin=\(m.binary?.count ?? 0)")
        }
        if let handler = handlers[m.msgId] {
            if let reply = handler(m) {
                try? await send(reply)
            }
            return
        }
        if let sub = subscriptions[m.msgNum] {
            await sub.push(m)
        } else {
            log?("dropped unsolicited message id=\(m.msgId) num=\(m.msgNum)")
        }
    }
}

/// Runs `operation` with a deadline.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BCError.timeout
        }
        do {
            let result = try await group.next()!
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Resumes a continuation at most once, from any thread.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }

    func resume(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
