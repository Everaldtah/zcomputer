import Foundation
import ZCore

/// Proof of holding the input lease. Stale once released or expired (releasing a stale grant does nothing).
public struct LeaseGrant: Sendable, Hashable {
    public let holder: String
    /// Unique per hand-over; all references of one holding share it.
    public let token: UInt64
    public let acquiredAt: Date
}

/// Exclusive lock for *input* on a shared `ComputerSurface`: one holder at a time, first come first served.
///
/// * Re-entrant per holder: while `holder` holds the lease, its further `acquire` calls return at once and add a
///   reference; the lease is handed over when every reference is released.
/// * `maxHoldTime` bounds one holding: after it the lease is taken back (`LeaseEvent.expired`), the holder's
///   expiry handler runs (e.g. to release keys it still holds) and the next waiter gets it.
/// * Waiting is cancellable: a cancelled `acquire` leaves the queue and throws `CancellationError`.
/// Screenshots never take the lease (see `LeasedSurface`).
public actor SurfaceLease {
    /// Seconds one holding may last (0 or less = unlimited).
    public nonisolated let maxHoldTime: TimeInterval
    /// Longest wait for an expiry handler before the lease moves on anyway.
    public nonisolated let expiryHandlerTimeout: TimeInterval
    public nonisolated let reporter: TeamReporter?

    private struct Holding {
        var holder: String
        var token: UInt64
        var acquiredAt: Date
        var refCount: Int
        var watchdog: Task<Void, Never>?
        var expiring: Bool
    }

    private struct Waiter {
        var id: UUID
        var holder: String
        var enqueuedAt: Date
        var continuation: CheckedContinuation<LeaseGrant, Error>
    }

    private var current: Holding?
    private var queue: [Waiter] = []
    private var nextToken: UInt64 = 1
    private var expiryHandlers: [String: @Sendable () async -> Void] = [:]

    public init(maxHoldTime: TimeInterval = 30, expiryHandlerTimeout: TimeInterval = 2, reporter: TeamReporter? = nil) {
        self.maxHoldTime = maxHoldTime
        self.expiryHandlerTimeout = max(0, expiryHandlerTimeout)
        self.reporter = reporter
    }

    // MARK: State

    /// Who holds the lease now (nil = free).
    public var holder: String? { current?.holder }
    public var isHeld: Bool { current != nil }
    /// Holders waiting, in order.
    public var waiting: [String] { queue.map(\.holder) }

    /// Whether `grant` is still the live holding.
    public func isValid(_ grant: LeaseGrant) -> Bool {
        guard let h = current else { return false }
        return h.token == grant.token && !h.expiring
    }

    /// Typed lease events (only when the lease has a reporter).
    public nonisolated func events() -> AsyncStream<LeaseEvent> {
        guard let hub = reporter?.hub else { return AsyncStream { $0.finish() } }
        let upstream = hub.subscribe()
        return AsyncStream { continuation in
            let pump = Task {
                for await event in upstream {
                    if case .lease(let e) = event { continuation.yield(e) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    // MARK: Acquire / release

    /// Waits for the lease (FIFO) and returns the grant; at once when `holder` already holds it.
    /// Throws `CancellationError` when the calling task is cancelled while waiting, or `cancelAll()` is called.
    public func acquire(holder: String) async throws -> LeaseGrant {
        try Task.checkCancellation()
        if var h = current, h.holder == holder, !h.expiring {
            h.refCount += 1
            current = h
            return LeaseGrant(holder: holder, token: h.token, acquiredAt: h.acquiredAt)
        }
        if current == nil, queue.isEmpty {
            return take(holder: holder, waitingSince: Date())
        }
        let id = UUID()
        let owner = current?.holder ?? queue.first?.holder ?? ""
        report(.waiting(holder: holder, owner: owner, position: queue.count + 1))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<LeaseGrant, Error>) in
                queue.append(Waiter(id: id, holder: holder, enqueuedAt: Date(), continuation: c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Drops one reference of `grant`; the lease passes to the next waiter when none is left.
    /// Stale grants (released or expired) are ignored.
    public func release(_ grant: LeaseGrant) {
        guard var h = current, h.token == grant.token, !h.expiring else { return }
        h.refCount -= 1
        if h.refCount > 0 {
            current = h
            return
        }
        h.watchdog?.cancel()
        current = nil
        report(.released(holder: h.holder, held: Date().timeIntervalSince(h.acquiredAt)))
        grantNext()
    }

    /// Runs `body` holding the lease (re-entrant for the same holder) and releases it afterwards, also on error.
    public nonisolated func withLease<T: Sendable>(holder: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let grant = try await acquire(holder: holder)
        do {
            let value = try await body()
            await release(grant)
            return value
        } catch {
            await release(grant)
            throw error
        }
    }

    /// Code to run when `holder`'s lease is taken back (max hold time) before the next holder gets it — e.g.
    /// releasing keys and mouse buttons it still holds. It must not wait for the lease itself.
    public func setExpiryHandler(for holder: String, _ handler: (@Sendable () async -> Void)?) {
        expiryHandlers[holder] = handler
    }

    /// Fails every waiter with `CancellationError` and frees the lease (the team was stopped).
    public func cancelAll() {
        let waiters = queue
        queue.removeAll()
        for w in waiters { w.continuation.resume(throwing: CancellationError()) }
        if let h = current {
            h.watchdog?.cancel()
            current = nil
            report(.released(holder: h.holder, held: Date().timeIntervalSince(h.acquiredAt)))
        }
    }

    // MARK: Internals

    private func take(holder: String, waitingSince: Date) -> LeaseGrant {
        let token = nextToken
        nextToken += 1
        let now = Date()
        current = Holding(holder: holder, token: token, acquiredAt: now, refCount: 1,
                          watchdog: startWatchdog(token: token), expiring: false)
        report(.acquired(holder: holder, waited: max(0, now.timeIntervalSince(waitingSince))))
        return LeaseGrant(holder: holder, token: token, acquiredAt: now)
    }

    /// Hands the lease to the first waiter; its other waiting calls (same holder) share the holding.
    private func grantNext() {
        guard current == nil, !queue.isEmpty else { return }
        let first = queue.removeFirst()
        let grant = take(holder: first.holder, waitingSince: first.enqueuedAt)
        let same = queue.filter { $0.holder == first.holder }
        if !same.isEmpty {
            queue.removeAll { $0.holder == first.holder }
            if var h = current {
                h.refCount += same.count
                current = h
            }
        }
        first.continuation.resume(returning: grant)
        for w in same { w.continuation.resume(returning: grant) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let w = queue.remove(at: i)
        w.continuation.resume(throwing: CancellationError())
    }

    private func startWatchdog(token: UInt64) -> Task<Void, Never>? {
        guard maxHoldTime > 0, maxHoldTime.isFinite else { return nil }
        let nanos = UInt64(min(maxHoldTime, 86_400) * 1_000_000_000)
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.expire(token: token)
        }
    }

    private func expire(token: UInt64) async {
        guard var h = current, h.token == token, !h.expiring else { return }
        h.expiring = true
        current = h
        report(.expired(holder: h.holder, held: Date().timeIntervalSince(h.acquiredAt)))
        if let handler = expiryHandlers[h.holder] {
            await Self.run(handler, timeout: expiryHandlerTimeout)
        }
        // cancelAll() may have run meanwhile.
        guard let now = current, now.token == token else { return }
        current = nil
        grantNext()
    }

    private func report(_ event: LeaseEvent) {
        reporter?.report(.lease(event))
    }

    /// Runs `handler`, returning when it finishes or after `timeout` seconds, whichever comes first.
    private static func run(_ handler: @escaping @Sendable () async -> Void, timeout: TimeInterval) async {
        let once = OnceFlag()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let work = Task {
                await handler()
                if once.claim() { c.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    c.resume()
                }
            }
        }
    }
}

/// A flag that can be claimed once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
