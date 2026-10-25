import Foundation
import BaiduKit
import DownloadKit

/// 所有 copy／rename 必须使用服务端 no-replace；resolve 必须核对准确身份与大小。
public protocol UploadReplacementDestination: Sendable {
    var account: AccountKey { get }
    func find(parent: RemoteReference, name: String) async throws -> RemoteEntry?
    func resolve(reference: RemoteReference, size: Int64) async throws -> ResolvedURL
    /// 在快照意图落盘前检查所需空间；只读检查失败不形成未知写操作。
    func checkSnapshotCapacity(size: Int64) async throws
    func copy(source: RemoteReference, newName: String) async throws
    func rename(source: RemoteReference, newName: String) async throws
}

public enum UploadReplacementError: LocalizedError, Sendable, Equatable {
    case unconfirmed, conflict(String), contentMismatch
    public var errorDescription: String? {
        switch self {
        case .unconfirmed: "覆盖操作结果未确认，保留检查点与全部对象"
        case .conflict(let reason): reason
        case .contentMismatch: "覆盖对象完整 SHA-256 不一致"
        }
    }
}

/// 独立快照、claim 核对和 no-replace 发布；不删除旧内容，也不自动重发未知写请求。
public struct UploadReplacementPublisher: Sendable {
    private let destination: any UploadReplacementDestination
    private let integrity: IntegrityService
    public init(destination: any UploadReplacementDestination, integrity: IntegrityService) {
        self.destination = destination; self.integrity = integrity
    }

    /// 完整取得旧内容基准并保存独立云端快照；copy 未决仅查询原槽位。
    public func prepare(_ state: UploadReplacementState,
                        checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws -> UploadReplacementState {
        var state = state
        try check(state)
        if state.stage == .conflict { throw UploadReplacementError.conflict(state.conflictReason!) }
        if state.stage == .initial {
            try Task.checkCancellation()
            guard let current = try await find(state, name: state.original.name),
                  sameObject(current.reference, state.original.reference), current.size == state.original.size else {
                throw UploadReplacementError.conflict("原目标在建立内容基准前已变化")
            }
            state.account = destination.account
            state.originalSHA256 = try await digest(current.reference, size: current.size)
            try Task.checkCancellation()
            try await destination.checkSnapshotCapacity(size: current.size)
            try Task.checkCancellation()
            guard try await find(state, name: state.snapshotName) == nil,
                  try await find(state, name: state.claimName) == nil else {
                throw UploadReplacementError.conflict("覆盖专用槽位已被占用")
            }
            let previous = state
            state.stage = .snapshotPending
            do {
                try await submit(previous: previous, intent: state, checkpoint: checkpoint) {
                    try await destination.copy(source: current.reference, newName: state.snapshotName)
                }
            } catch BaiduError.alreadyExists {
                try await conflict(&state, "快照槽位被占用，停止覆盖", checkpoint: checkpoint)
            }
        }
        if state.stage == .snapshotPending { try await confirmSnapshot(&state, checkpoint: checkpoint) }
        try check(state)
        return state
    }

    /// 暂存完整校验后 claim 当前路径绑定；只发布准确的新对象，冲突保全所有版本。
    public func publish(_ state: UploadReplacementState, staged: RemoteReference,
                        expectedSHA256: String, size: Int64,
                        checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws -> UploadReplacementState {
        try check(state)
        if state.stage == .conflict { throw UploadReplacementError.conflict(state.conflictReason!) }
        let expected = try IntegrityExpectation(algorithm: .sha256, digest: expectedSHA256, origin: .localOriginal,
                                                size: size, reference: staged).digest
        guard staged.provider == destination.account.provider, !sameObject(staged, state.original.reference),
              state.stagedObject.map({ sameObject($0, staged) }) ?? true,
              state.stagedSHA256.map({ $0 == expected }) ?? true,
              state.stagedSize.map({ $0 == size }) ?? true else { throw UploadRecordError.invalid("恢复发布的暂存对象或摘要已变化") }
        var state = try await prepare(state, checkpoint: checkpoint)
        if state.stage == .published {
            try await verifyFinal(state)
            return state
        }
        if state.stage == .snapshotReady {
            guard let candidate = try await find(state, name: state.stagingName),
                  sameObject(candidate.reference, staged), candidate.size == size else { throw UploadReplacementError.unconfirmed }
            guard try await digest(candidate.reference, size: size) == expected else { throw UploadReplacementError.contentMismatch }
            state.stagedObject = candidate.reference; state.stagedSHA256 = expected; state.stagedSize = size
            // claim 前重新校验独立快照，避免恢复后把已经变化的快照当成旧字节保障。
            guard let snapshot = try await find(state, name: state.snapshotName),
                  sameObject(snapshot.reference, state.snapshotObject!), snapshot.size == state.original.size,
                  try await digest(snapshot.reference, size: snapshot.size) == state.originalSHA256 else {
                try await conflict(&state, "旧内容快照已变化，停止覆盖", checkpoint: checkpoint)
            }
            state.snapshotVerifiedAt = .now
            guard let current = try await find(state, name: state.original.name) else { throw UploadReplacementError.unconfirmed }
            let previous = state
            state.stage = .claimPending
            do {
                try await submit(previous: previous, intent: state, checkpoint: checkpoint) {
                    try await destination.rename(source: current.reference, newName: state.claimName)
                }
            } catch BaiduError.alreadyExists {
                try await conflict(&state, "claim 槽位被占用，停止覆盖", checkpoint: checkpoint)
            }
        }
        if state.stage == .claimPending { try await confirmClaim(&state, checkpoint: checkpoint) }
        if state.stage == .claimed {
            guard let claimed = try await find(state, name: state.claimName),
                  sameObject(claimed.reference, state.claimedObject!), claimed.size == state.claimedSize else { throw UploadReplacementError.unconfirmed }
            state.claimedSHA256 = try await digest(claimed.reference, size: claimed.size)
            try await checkpoint(state)
            if !sameObject(claimed.reference, state.original.reference) || claimed.size != state.original.size || state.claimedSHA256 != state.originalSHA256 {
                let previous = state
                state.stage = .restorePending
                do {
                    try await submit(previous: previous, intent: state, checkpoint: checkpoint) {
                        try await destination.rename(source: claimed.reference, newName: state.original.name)
                    }
                } catch BaiduError.alreadyExists {
                    try await conflict(&state, "目标已被其他对象占用，保留误 claim 对象与旧内容快照", checkpoint: checkpoint)
                }
            } else {
                let previous = state
                state.stage = .publishPending
                do {
                    try await submit(previous: previous, intent: state, checkpoint: checkpoint) {
                        try await destination.rename(source: staged, newName: state.original.name)
                    }
                } catch BaiduError.alreadyExists {
                    try await conflict(&state, "目标已被其他对象占用，保留暂存对象、claim 与旧内容快照", checkpoint: checkpoint)
                }
            }
        }
        if state.stage == .restorePending { try await confirmRestoration(&state, checkpoint: checkpoint) }
        if state.stage == .publishPending { try await confirmPublication(&state, checkpoint: checkpoint) }
        try check(state)
        return state
    }

    /// 取消只核对已发操作并恢复准确 claim，不发布新内容，也不删除快照或未知对象。
    /// 调用方应在旧 worker 收尾后以未取消任务调用，检查点保存失败仍保留原未决状态。
    public func cancel(_ state: UploadReplacementState,
                       checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws -> UploadReplacementState {
        var state = state
        try check(state)
        if state.stage == .snapshotPending { try await confirmSnapshot(&state, checkpoint: checkpoint) }
        if state.stage == .publishPending { try await confirmPublication(&state, occupiedIsConflict: true, checkpoint: checkpoint) }
        if state.stage == .claimPending { try await confirmClaim(&state, requireKnownIdentity: true, checkpoint: checkpoint) }
        if state.stage == .claimed {
            guard let claimed = try await find(state, name: state.claimName),
                  sameObject(claimed.reference, state.claimedObject!), claimed.size == state.claimedSize else {
                throw UploadReplacementError.unconfirmed
            }
            state.claimedSHA256 = try await digest(claimed.reference, size: claimed.size)
            let previous = state
            state.stage = .restorePending
            do {
                try await submit(previous: previous, intent: state, checkpoint: checkpoint) {
                    try await destination.rename(source: claimed.reference, newName: state.original.name)
                }
            } catch BaiduError.alreadyExists {
                try await conflict(&state, "取消时原名被占用，保留占位对象、claim 与旧内容快照", checkpoint: checkpoint)
            }
        }
        if state.stage == .restorePending { try await confirmRestoration(&state, checkpoint: checkpoint) }
        try check(state)
        return state
    }

    /// 公开核对入口只查询已经提交的唯一槽位；确认 claim 后停在 claimed，不隐式发布或恢复名称。
    public func inspect(_ state: UploadReplacementState,
                        checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws -> UploadReplacementState {
        var state = state
        try check(state)
        switch state.stage {
        case .snapshotPending: try await confirmSnapshot(&state, checkpoint: checkpoint)
        case .claimPending: try await confirmClaim(&state, checkpoint: checkpoint)
        case .publishPending: try await confirmPublication(&state, checkpoint: checkpoint)
        case .restorePending: try await confirmRestoration(&state, checkpoint: checkpoint)
        case .published: try await verifyFinal(state)
        case .initial, .snapshotReady, .claimed, .conflict: break
        }
        try check(state)
        return state
    }

    /// copy 未决只能查询唯一快照并完整核验，缺失时保留意图而不重发。
    private func confirmSnapshot(_ state: inout UploadReplacementState,
                                 checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws {
        guard let snapshot = try await find(state, name: state.snapshotName) else { throw UploadReplacementError.unconfirmed }
        guard !sameObject(snapshot.reference, state.original.reference), snapshot.size == state.original.size,
              try await digest(snapshot.reference, size: snapshot.size) == state.originalSHA256 else {
            try await conflict(&state, "独立快照与旧内容基准不一致", checkpoint: checkpoint)
        }
        state.snapshotObject = snapshot.reference; state.snapshotVerifiedAt = .now; state.stage = .snapshotReady
        try await checkpoint(state)
    }

    /// 保存查询到的准确 claim 回执；取消入口对尚未保存过的陌生身份保持未确认。
    private func confirmClaim(_ state: inout UploadReplacementState, requireKnownIdentity: Bool = false,
                              checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws {
        guard let claimed = try await find(state, name: state.claimName) else { throw UploadReplacementError.unconfirmed }
        if requireKnownIdentity, !sameObject(claimed.reference, state.claimedObject ?? state.original.reference) {
            throw UploadReplacementError.unconfirmed
        }
        state.claimedObject = claimed.reference; state.claimedSize = claimed.size; state.stage = .claimed
        try await checkpoint(state)
    }

    /// rename 回执未知时按已存暂存身份与完整摘要确认最终对象，不再发送发布请求。
    private func confirmPublication(_ state: inout UploadReplacementState, occupiedIsConflict: Bool = false,
                                    checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws {
        guard let final = try await find(state, name: state.original.name) else { throw UploadReplacementError.unconfirmed }
        guard sameObject(final.reference, state.stagedObject!), final.size == state.stagedSize else {
            if occupiedIsConflict { try await conflict(&state, "取消时目标已被其他对象占用，保留所有对象", checkpoint: checkpoint) }
            throw UploadReplacementError.unconfirmed
        }
        guard try await digest(final.reference, size: final.size) == state.stagedSHA256 else {
            try await conflict(&state, "最终对象内容已变化，保留旧内容快照", checkpoint: checkpoint)
        }
        state.finalObject = final.reference; state.stage = .published
        try await checkpoint(state)
    }

    /// 恢复回执未知只查原名；误 claim 恢复后报告冲突，正常取消恢复后保留快照。
    private func confirmRestoration(_ state: inout UploadReplacementState,
                                    checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws {
        guard let restored = try await find(state, name: state.original.name) else { throw UploadReplacementError.unconfirmed }
        guard sameObject(restored.reference, state.claimedObject!), restored.size == state.claimedSize,
              try await digest(restored.reference, size: restored.size) == state.claimedSHA256 else {
            try await conflict(&state, "恢复时原名被其他对象占用或内容已变化，保留全部对象", checkpoint: checkpoint)
        }
        if !sameObject(restored.reference, state.original.reference) || state.claimedSHA256 != state.originalSHA256 {
            try await conflict(&state, "原目标已变化，已恢复其准确对象；新文件未发布，旧内容快照保留", checkpoint: checkpoint)
        }
        state.stage = .snapshotReady
        try await checkpoint(state)
    }

    /// 进入调用前已取消时撤回未发送意图；调用开始后的错误保持原 pending，不推断未提交。
    private func submit(previous: UploadReplacementState, intent: UploadReplacementState,
                        checkpoint: @Sendable (UploadReplacementState) async throws -> Void,
                        action: () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await checkpoint(intent)
        do { try Task.checkCancellation() }
        catch { try await checkpoint(previous); throw error }
        try await action()
    }

    /// 恢复入口固定账号并验证记录，冲突终态不会再发写请求。
    private func check(_ state: UploadReplacementState) throws {
        try state.validate()
        guard state.parent.provider == destination.account.provider,
              state.account == nil || state.account == destination.account else { throw UploadRecordError.invalid("覆盖发布账号已变化") }
    }

    /// 目录查询必须返回所请求槽位的普通文件；错误数据不能被当成准确产物。
    private func find(_ state: UploadReplacementState, name: String) async throws -> RemoteEntry? {
        guard let entry = try await destination.find(parent: state.parent, name: name) else { return nil }
        guard entry.name == name, !entry.isDirectory, entry.size >= 0, entry.reference.provider == state.parent.provider else {
            throw UploadRecordError.invalid("覆盖目录查询返回错误对象")
        }
        switch entry.reference {
        case .baidu(_, let id):
            guard id > 0 else { throw UploadRecordError.invalid("覆盖查询缺少准确 fsID") }
        case .quark(let fid):
            guard !fid.isEmpty, fid != "0" else { throw UploadRecordError.invalid("覆盖查询缺少准确 fid") }
        }
        return entry
    }

    /// 每次完整回读交给同一校验服务与准确身份解析，不持有完整文件副本。
    private func digest(_ reference: RemoteReference, size: Int64) async throws -> String {
        try await integrity.captureSHA256(size: size) { try await destination.resolve(reference: reference, size: size) }
    }

    /// 发布完成后的恢复仍核对当前目标身份和新内容，不能仅凭旧 completed 记录返回成功。
    private func verifyFinal(_ state: UploadReplacementState) async throws {
        guard let final = try await find(state, name: state.original.name),
              sameObject(final.reference, state.finalObject!), final.size == state.stagedSize,
              try await digest(final.reference, size: final.size) == state.stagedSHA256 else { throw UploadReplacementError.contentMismatch }
    }

    /// 冲突先保存明确终态，全部旧对象与未知对象由调用方展示，不在此删除。
    private func conflict(_ state: inout UploadReplacementState, _ reason: String,
                          checkpoint: @Sendable (UploadReplacementState) async throws -> Void) async throws -> Never {
        state.stage = .conflict; state.conflictReason = reason
        try await checkpoint(state)
        throw UploadReplacementError.conflict(reason)
    }

    /// 百度 rename 改变路径但不改变 fsID；夸克使用 fid，不按名称或大小猜身份。
    private func sameObject(_ lhs: RemoteReference, _ rhs: RemoteReference) -> Bool {
        switch (lhs, rhs) {
        case (.baidu(_, let a), .baidu(_, let b)): a > 0 && a == b
        case (.quark(let a), .quark(let b)): !a.isEmpty && a == b
        default: false
        }
    }
}
