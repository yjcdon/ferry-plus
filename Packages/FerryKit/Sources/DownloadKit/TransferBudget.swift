import Foundation

/// 上传独立限速；下载与上传后的校验回读使用同一个 download 预算。
public enum TransferBudgetDirection: String, Sendable, Hashable { case upload, download }

public enum TransferBudgetError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidByteCount
    case shutDown
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "连接上限必须大于零，速率不能为负数"
        case .invalidByteCount: "传输字节数不能为负数"
        case .shutDown: "传输资源预算已关闭"
        }
    }
}

/// 三类传输共用连接许可；每个方向用总速率令牌桶背压，不创建空闲 ticker。
/// 调用方在读取或发送有界缓冲之前消费字节预算，URLSession 自身缓冲仍由消费者限制。
public actor TransferBudget {
    public struct Lease: Sendable, Hashable { fileprivate let id: UUID }
    public struct Snapshot: Sendable {
        public let activeConnections: Int
        public let waitingConnections: Int
        public let waitingUploadBuffers: Int
        public let waitingDownloadBuffers: Int
        public let activeRateTimers: Int
    }

    private struct ConnectionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, any Error>
    }
    private struct ByteWaiter {
        let id: UUID
        var remaining: Double
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct RateState {
        var rate: Int64
        var tokens: Double
        var updatedAt: ContinuousClock.Instant
        var waiters: [ByteWaiter] = []
        var timer: Task<Void, Never>?
        var generation: UInt64 = 0
        var capacity: Double { max(1, Double(rate) / 10) }
    }

    private let clock = ContinuousClock()
    private var maximumConnections: Int
    private var active: Set<UUID> = []
    private var connections: [ConnectionWaiter] = []
    private var rates: [TransferBudgetDirection: RateState]
    private var closed = false

    /// bytesPerSecond 为零表示不限速；令牌桶最大突发为约 100 毫秒。
    public init(maximumConnections: Int = 20, uploadBytesPerSecond: Int64 = 0,
                downloadBytesPerSecond: Int64 = 0) throws {
        guard maximumConnections > 0, uploadBytesPerSecond >= 0, downloadBytesPerSecond >= 0 else {
            throw TransferBudgetError.invalidConfiguration
        }
        self.maximumConnections = maximumConnections
        let now = ContinuousClock.now
        rates = [
            .upload: RateState(rate: uploadBytesPerSecond, tokens: max(1, Double(uploadBytesPerSecond) / 10), updatedAt: now),
            .download: RateState(rate: downloadBytesPerSecond, tokens: max(1, Double(downloadBytesPerSecond) / 10), updatedAt: now)
        ]
    }

    deinit {
        for waiter in connections { waiter.continuation.resume(throwing: CancellationError()) }
        for state in rates.values {
            state.timer?.cancel()
            for waiter in state.waiters { waiter.continuation.resume(throwing: CancellationError()) }
        }
    }

    /// FIFO 取得许可；取消与授予同时发生时会归还已授予的许可。
    public func acquire() async throws -> Lease {
        try Task.checkCancellation()
        guard !closed else { throw TransferBudgetError.shutDown }
        let id = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                connections.append(ConnectionWaiter(id: id, continuation: continuation))
                grantConnections()
            }
        } onCancel: { Task { await self.cancelConnection(id) } }
        do { try Task.checkCancellation(); return lease }
        catch { release(lease); throw error }
    }

    /// 释放是幂等的；已关闭预算仍接受在途 worker 归还许可。
    public func release(_ lease: Lease) {
        guard active.remove(lease.id) != nil else { return }
        grantConnections()
    }

    /// 推荐的许可入口，闭包抛错或取消都会归还连接。
    public func withPermit<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
        let lease = try await acquire()
        defer { release(lease) }
        return try await operation()
    }

    /// 等待有界缓冲的字节额度；同方向所有消费者按到达顺序共享速率。
    public func consume(_ bytes: Int, direction: TransferBudgetDirection) async throws {
        guard bytes >= 0 else { throw TransferBudgetError.invalidByteCount }
        try Task.checkCancellation()
        guard !closed else { throw TransferBudgetError.shutDown }
        guard bytes > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                rates[direction]!.waiters.append(ByteWaiter(id: id, remaining: Double(bytes), continuation: continuation))
                pump(direction)
            }
        } onCancel: { Task { await self.cancelBytes(id, direction: direction) } }
        try Task.checkCancellation()
    }

    /// 降低连接上限不打断现有请求；新许可等待释放。速率更新立即唤醒对应等待者。
    public func update(maximumConnections: Int, uploadBytesPerSecond: Int64, downloadBytesPerSecond: Int64) throws {
        guard maximumConnections > 0, uploadBytesPerSecond >= 0, downloadBytesPerSecond >= 0 else {
            throw TransferBudgetError.invalidConfiguration
        }
        guard !closed else { throw TransferBudgetError.shutDown }
        self.maximumConnections = maximumConnections
        updateRate(.upload, to: uploadBytesPerSecond)
        updateRate(.download, to: downloadBytesPerSecond)
        grantConnections()
    }

    /// 关闭后停止定时等待并结束排队请求；在途许可由 worker 正常释放。
    public func shutdown() {
        guard !closed else { return }
        closed = true
        let waiting = connections; connections.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: TransferBudgetError.shutDown) }
        for direction in [TransferBudgetDirection.upload, .download] {
            var state = rates[direction]!
            state.timer?.cancel(); state.timer = nil; state.generation &+= 1
            let waiting = state.waiters; state.waiters.removeAll()
            rates[direction] = state
            for waiter in waiting { waiter.continuation.resume(throwing: TransferBudgetError.shutDown) }
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(activeConnections: active.count, waitingConnections: connections.count,
                 waitingUploadBuffers: rates[.upload]!.waiters.count,
                 waitingDownloadBuffers: rates[.download]!.waiters.count,
                 activeRateTimers: rates.values.filter { $0.timer != nil }.count)
    }

    private func grantConnections() {
        guard !closed else { return }
        while active.count < maximumConnections, !connections.isEmpty {
            let waiter = connections.removeFirst()
            active.insert(waiter.id)
            waiter.continuation.resume(returning: Lease(id: waiter.id))
        }
    }

    private func cancelConnection(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelBytes(_ id: UUID, direction: TransferBudgetDirection) {
        guard let index = rates[direction]!.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = rates[direction]!.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        pump(direction)
    }

    private func updateRate(_ direction: TransferBudgetDirection, to rate: Int64) {
        var state = rates[direction]!
        refill(&state)
        let wasUnlimited = state.rate == 0
        state.rate = rate
        state.tokens = wasUnlimited ? state.capacity : min(state.tokens, state.capacity)
        rates[direction] = state
        pump(direction)
    }

    private func refill(_ state: inout RateState) {
        let now = clock.now
        let elapsed = state.updatedAt.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        state.tokens = min(state.capacity, state.tokens + max(0, seconds) * Double(state.rate))
        state.updatedAt = now
    }

    /// 每个方向最多一个短期定时任务；队列清空后不再调度。
    private func pump(_ direction: TransferBudgetDirection) {
        var state = rates[direction]!
        state.timer?.cancel(); state.timer = nil; state.generation &+= 1
        refill(&state)
        while !state.waiters.isEmpty {
            if state.rate == 0 {
                state.waiters.removeFirst().continuation.resume()
            } else {
                let granted = min(state.tokens, state.waiters[0].remaining)
                state.tokens -= granted; state.waiters[0].remaining -= granted
                guard state.waiters[0].remaining < 0.000001 else { break }
                state.waiters.removeFirst().continuation.resume()
            }
        }
        if !state.waiters.isEmpty {
            let delay = max(0.001, min(state.capacity, state.waiters[0].remaining) / Double(state.rate))
            let generation = state.generation
            state.timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.wake(direction, generation: generation)
            }
        }
        rates[direction] = state
    }

    private func wake(_ direction: TransferBudgetDirection, generation: UInt64) {
        guard !closed, rates[direction]!.generation == generation else { return }
        pump(direction)
    }
}
