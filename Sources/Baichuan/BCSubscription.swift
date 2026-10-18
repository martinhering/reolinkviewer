import Foundation

/// Mailbox for replies to one message number. The connection pushes messages in; one consumer
/// pulls them out, optionally with a timeout that does not invalidate the subscription.
public actor BCSubscription {
    public let msgNum: UInt16
    private var queue: [BCMessage] = []
    private var waiter: CheckedContinuation<BCMessage?, Never>?
    private var generation = 0
    private var terminalError: Error?

    init(msgNum: UInt16) {
        self.msgNum = msgNum
    }

    func push(_ m: BCMessage) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: m)
        } else {
            queue.append(m)
        }
    }

    func finish(_ error: Error) {
        if terminalError == nil { terminalError = error }
        if let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
    }

    /// Waits for the next message. Throws when the connection closes or the task is cancelled.
    public func next() async throws -> BCMessage {
        if !queue.isEmpty { return queue.removeFirst() }
        if let e = terminalError { throw e }
        try Task.checkCancellation()
        generation += 1
        let gen = generation
        let m = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<BCMessage?, Never>) in waiter = c }
        } onCancel: {
            Task { await self.expire(generation: gen) }
        }
        guard let m else {
            if Task.isCancelled { throw CancellationError() }
            throw terminalError ?? BCError.connectionClosed
        }
        return m
    }

    /// Waits up to `timeout` seconds. On timeout the subscription stays usable. Unlike `next()`,
    /// this ignores task cancellation so a cancelled stream can still wait for its stop acknowledgement.
    public func next(timeout: TimeInterval) async throws -> BCMessage {
        if !queue.isEmpty { return queue.removeFirst() }
        if let e = terminalError { throw e }
        generation += 1
        let gen = generation
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await self?.expire(generation: gen)
        }
        defer { timer.cancel() }
        let m = await withCheckedContinuation { (c: CheckedContinuation<BCMessage?, Never>) in waiter = c }
        guard let m else { throw terminalError ?? BCError.timeout }
        return m
    }

    private func expire(generation gen: Int) {
        guard gen == generation, let w = waiter else { return }
        waiter = nil
        w.resume(returning: nil)
    }
}
