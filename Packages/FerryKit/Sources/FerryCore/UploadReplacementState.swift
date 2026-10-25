import Foundation

/// 覆盖发布的持久检查点；保存准确对象与唯一槽位，不包含授权或下载地址。
public struct UploadReplacementState: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case initial, snapshotPending, snapshotReady, claimPending, claimed
        case restorePending, publishPending, published, conflict
    }
    public let fileID: UUID
    public let parent: RemoteReference
    public let original: RemoteEntry
    public let stagingName: String
    public let snapshotName: String
    public let claimName: String
    public var stage: Stage = .initial
    public var account: AccountKey?
    public var originalSHA256: String?
    public var snapshotObject: RemoteReference?
    public var claimedObject: RemoteReference?
    public var claimedSize: Int64?
    public var claimedSHA256: String?
    public var stagedObject: RemoteReference?
    public var stagedSHA256: String?
    public var stagedSize: Int64?
    public var finalObject: RemoteReference?
    public var conflictReason: String?

    /// 已发送但尚未取得准确结果的远端操作，移除记录前必须保留恢复线索。
    public var hasPendingRemoteOperation: Bool {
        [.snapshotPending, .claimPending, .restorePending, .publishPending].contains(stage)
    }

    /// claim 已释放原名也须收尾；终态及尚未 claim 的阶段没有需要恢复的名称空窗。
    public var requiresCancellationRecovery: Bool { hasPendingRemoteOperation || stage == .claimed }

    /// 一个上传文件固定三个 ASCII 名称，恢复不能重新选择槽位或认领同名用户对象。
    public init(fileID: UUID, parent: RemoteReference, original: RemoteEntry) throws {
        self.fileID = fileID; self.parent = parent; self.original = original
        let token = fileID.uuidString.lowercased()
        stagingName = "ferry-\(token)-staging"
        snapshotName = "ferry-\(token)-snapshot"
        claimName = "ferry-\(token)-claim"
        try validate()
    }

    /// 解码后、执行前检查完整阶段约束；坏记录不能被当成新发布重新发送。
    public func validate() throws {
        let token = fileID.uuidString.lowercased()
        guard stagingName == "ferry-\(token)-staging", snapshotName == "ferry-\(token)-snapshot",
              claimName == "ferry-\(token)-claim", !original.isDirectory, original.size >= 0,
              !original.name.isEmpty, !original.name.contains("/"), ![".", "..", stagingName, snapshotName, claimName].contains(original.name),
              original.reference.provider == parent.provider else { throw UploadRecordError.invalid("覆盖发布的目标或唯一槽位无效") }
        for reference in [Optional(original.reference), snapshotObject, claimedObject, stagedObject, finalObject].compactMap({ $0 }) {
            guard reference.provider == parent.provider else { throw UploadRecordError.invalid("覆盖对象网盘不一致") }
            switch reference {
            case .baidu(let path, let id):
                guard path.hasPrefix("/"), id > 0 else { throw UploadRecordError.invalid("覆盖对象缺少准确百度身份") }
            case .quark(let fid):
                guard !fid.isEmpty else { throw UploadRecordError.invalid("覆盖对象缺少准确夸克身份") }
            }
        }
        switch parent {
        case .baidu(let path, let id):
            guard path.hasPrefix("/"), id >= 0 else { throw UploadRecordError.invalid("覆盖父目录无效") }
        case .quark(let fid):
            guard !fid.isEmpty else { throw UploadRecordError.invalid("覆盖父目录无效") }
        }
        if let account, account.provider != parent.provider || account.accountID.isEmpty { throw UploadRecordError.invalid("覆盖账号无效") }
        for digest in [originalSHA256, claimedSHA256, stagedSHA256].compactMap({ $0 }) {
            guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw UploadRecordError.invalid("覆盖 SHA-256 无效")
            }
        }
        if let stagedSize, stagedSize < 0 { throw UploadRecordError.invalid("暂存大小无效") }
        func sameIdentity(_ a: RemoteReference, _ b: RemoteReference) -> Bool {
            switch (a, b) {
            case (.baidu(_, let x), .baidu(_, let y)): x == y
            case (.quark(let x), .quark(let y)): x == y
            default: false
            }
        }
        if let snapshotObject, sameIdentity(snapshotObject, original.reference) {
            throw UploadRecordError.invalid("旧内容快照必须是独立对象")
        }
        if let stagedObject, sameIdentity(stagedObject, original.reference) || snapshotObject.map({ sameIdentity(stagedObject, $0) }) == true {
            throw UploadRecordError.invalid("暂存对象不能复用旧对象或快照身份")
        }
        if let finalObject, stagedObject.map({ sameIdentity(finalObject, $0) }) != true {
            throw UploadRecordError.invalid("最终对象必须沿用暂存准确身份")
        }
        if stage != .initial {
            guard account != nil, originalSHA256 != nil else { throw UploadRecordError.invalid("覆盖发布缺少旧内容基准") }
        }
        if [.snapshotReady, .claimPending, .claimed, .restorePending, .publishPending, .published].contains(stage) {
            guard snapshotObject != nil else { throw UploadRecordError.invalid("覆盖发布缺少独立快照") }
        }
        if [.claimPending, .claimed, .restorePending, .publishPending, .published].contains(stage) {
            guard stagedObject != nil, stagedSHA256 != nil, let stagedSize, stagedSize >= 0 else { throw UploadRecordError.invalid("覆盖发布缺少暂存基准") }
        }
        if [.claimed, .restorePending, .publishPending, .published].contains(stage) {
            guard claimedObject != nil, let claimedSize, claimedSize >= 0 else { throw UploadRecordError.invalid("覆盖发布缺少 claim 对象") }
        }
        if [.publishPending, .published].contains(stage) {
            guard let claimedObject, sameIdentity(claimedObject, original.reference), claimedSize == original.size,
                  claimedSHA256 == originalSHA256 else { throw UploadRecordError.invalid("发布缺少准确旧对象 claim 核验") }
        }
        if stage == .restorePending, claimedSHA256 == nil { throw UploadRecordError.invalid("恢复误 claim 缺少内容基准") }
        if stage == .published, finalObject == nil { throw UploadRecordError.invalid("覆盖完成缺少最终对象") }
        if stage == .conflict, conflictReason?.isEmpty != false { throw UploadRecordError.invalid("覆盖冲突缺少原因") }
    }
}
