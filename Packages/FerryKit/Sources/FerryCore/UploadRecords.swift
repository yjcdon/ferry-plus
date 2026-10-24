import Foundation

/// 上传阶段独立于暂停、取消意图；提交中断后仍需核对远端结果。
public enum UploadPhase: String, Codable, Sendable, Hashable, CaseIterable {
    case preparing, queued, uploading, committing, verifying, publishing, completed, skipped, failed, cancelled
    public var isTerminal: Bool { [.completed, .skipped, .failed, .cancelled].contains(self) }
}

public enum UploadConflictPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case keepBoth, skip, replace
}

/// bookmark 负责授权，文件属性用于恢复核对；不保存完整源文件。
public struct UploadLocalSource: Codable, Sendable, Hashable {
    public var url: URL
    public var bookmark: Data?
    public var size: Int64
    public var modificationDate: Date?
    public var resourceIdentifier: Data?

    public init(url: URL, bookmark: Data? = nil, size: Int64,
                modificationDate: Date? = nil, resourceIdentifier: Data? = nil) {
        self.url = url; self.bookmark = bookmark; self.size = size
        self.modificationDate = modificationDate; self.resourceIdentifier = resourceIdentifier
    }
}

/// 只保存可恢复的协议身份。签名、Cookie、OSS 授权不能放入该记录。
public struct UploadSession: Codable, Sendable, Hashable {
    public var id: String
    public var account: AccountKey
    public var generation: UUID
    public var partSize: Int64
    public var expiresAt: Date?
    /// 无法重新取得的敏感恢复数据在 Keychain 中的引用。
    public var secretReference: String?
    public var objectKey: String?

    public init(id: String, account: AccountKey, partSize: Int64, generation: UUID = UUID(),
                expiresAt: Date? = nil, secretReference: String? = nil, objectKey: String? = nil) {
        self.id = id; self.account = account; self.partSize = partSize; self.generation = generation
        self.expiresAt = expiresAt; self.secretReference = secretReference; self.objectKey = objectKey
    }
}

/// 分片序号在公共层从零开始；适配器转换服务端序号。
public struct UploadPartReceipt: Codable, Sendable, Hashable {
    public let index: Int
    public let offset: Int64
    public let length: Int64
    public let sourceSHA256: String
    public let serverReceipt: String

    public init(index: Int, offset: Int64, length: Int64, sourceSHA256: String, serverReceipt: String) {
        self.index = index; self.offset = offset; self.length = length
        self.sourceSHA256 = sourceSHA256; self.serverReceipt = serverReceipt
    }
}

/// 服务端副作用前保存意图，响应丢失保留 pending，恢复时查询而不是盲目重提。
public struct UploadCommit: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable { case createDirectory, merge, replacement }
    public enum Status: String, Codable, Sendable, Hashable { case pending, confirmed, rejected }
    public let id: UUID
    public let kind: Kind
    public var status: Status
    public var taskID: String?
    public var stagingObject: RemoteReference?
    public var originalObject: RemoteReference?
    public var originalVersion: String?
    public var finalObject: RemoteReference?
    public var backupObject: RemoteReference?
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, status: Status = .pending, taskID: String? = nil,
                stagingObject: RemoteReference? = nil, originalObject: RemoteReference? = nil,
                originalVersion: String? = nil, finalObject: RemoteReference? = nil,
                backupObject: RemoteReference? = nil, createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.status = status; self.taskID = taskID
        self.stagingObject = stagingObject; self.originalObject = originalObject
        self.originalVersion = originalVersion; self.finalObject = finalObject
        self.backupObject = backupObject; self.createdAt = createdAt
    }
}

public enum IntegrityAlgorithm: String, Codable, Sendable, Hashable { case sha256, md5 }
public enum IntegrityOrigin: String, Codable, Sendable, Hashable { case localOriginal, remoteOriginal, userProvided }
public enum IntegrityStatus: String, Codable, Sendable, Hashable { case pending, verified, unavailable, mismatch }

/// 校验依据必须包含算法和来源，不能把未知 ETag 当作 MD5。
public struct IntegrityExpectation: Codable, Sendable, Hashable {
    public let algorithm: IntegrityAlgorithm
    public let digest: String
    public let origin: IntegrityOrigin
    public let size: Int64
    public var reference: RemoteReference?
    public var remoteVersion: String?

    public init(algorithm: IntegrityAlgorithm, digest: String, origin: IntegrityOrigin, size: Int64,
                reference: RemoteReference? = nil, remoteVersion: String? = nil) throws {
        self.algorithm = algorithm; self.digest = digest.lowercased(); self.origin = origin
        self.size = size; self.reference = reference; self.remoteVersion = remoteVersion
        try validate()
    }

    public func validate() throws {
        guard size >= 0, Self.isDigest(digest, algorithm: algorithm) else {
            throw UploadRecordError.invalid("校验摘要或文件大小无效")
        }
    }

    static func isDigest(_ value: String, algorithm: IntegrityAlgorithm) -> Bool {
        value.utf8.count == (algorithm == .sha256 ? 64 : 32) &&
            value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// 独立保存校验结果；移除上传任务不会删除原始摘要关联。
public struct IntegrityRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let account: AccountKey
    public let reference: RemoteReference
    public var remoteVersion: String?
    public var expectation: IntegrityExpectation?
    public var actualDigest: String?
    public var status: IntegrityStatus
    public var verifiedAt: Date?
    public var uploadFileID: UUID?
    public var error: String?

    public init(id: UUID = UUID(), account: AccountKey, reference: RemoteReference,
                remoteVersion: String? = nil, expectation: IntegrityExpectation? = nil,
                actualDigest: String? = nil, status: IntegrityStatus = .pending,
                verifiedAt: Date? = nil, uploadFileID: UUID? = nil, error: String? = nil) {
        self.id = id; self.account = account; self.reference = reference; self.remoteVersion = remoteVersion
        self.expectation = expectation; self.actualDigest = actualDigest?.lowercased(); self.status = status
        self.verifiedAt = verifiedAt; self.uploadFileID = uploadFileID; self.error = error
    }

    public func validate() throws {
        guard !account.accountID.isEmpty, account.provider == reference.provider, !reference.identifier.isEmpty else {
            throw UploadRecordError.invalid("校验记录的账号或远端身份无效")
        }
        try expectation?.validate()
        if let expectation, let actualDigest {
            guard IntegrityExpectation.isDigest(actualDigest, algorithm: expectation.algorithm) else {
                throw UploadRecordError.invalid("实际校验摘要无效")
            }
        }
        if status == .verified || status == .mismatch {
            guard let expectation, let actualDigest, verifiedAt != nil,
                  (expectation.digest == actualDigest) == (status == .verified) else {
                throw UploadRecordError.invalid("校验结果与摘要不一致")
            }
        }
        if let other = expectation?.reference, other != reference {
            throw UploadRecordError.invalid("校验依据属于不同远端文件")
        }
        if let expectedVersion = expectation?.remoteVersion, let remoteVersion, expectedVersion != remoteVersion {
            throw UploadRecordError.invalid("校验依据属于不同远端版本")
        }
    }
}

/// 单个文件或目录独立存盘，列表不必常驻完整目录树和分片回执。
public struct UploadFile: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let jobID: UUID
    public var relativePath: String
    /// 同名策略选定的远端名称；恢复不得重新选名而产生另一份文件。
    public var remoteName: String?
    public var isDirectory: Bool
    public var source: UploadLocalSource
    public var phase: UploadPhase
    public var failedPhase: UploadPhase?
    public var error: String?
    public var expectation: IntegrityExpectation?
    public var md5: String?
    public var sha1: String?
    public var session: UploadSession?
    /// 含原始内容指纹与原生会话；敏感授权仅保存 Keychain 引用。
    public var preparation: PreparedUpload?
    public var parts: [UploadPartReceipt]
    public var commits: [UploadCommit]
    public var remoteReference: RemoteReference?
    public var integrityRecordID: UUID?

    public init(id: UUID = UUID(), jobID: UUID, relativePath: String, isDirectory: Bool = false,
                source: UploadLocalSource, phase: UploadPhase = .preparing) {
        self.id = id; self.jobID = jobID; self.relativePath = relativePath; self.isDirectory = isDirectory
        self.source = source; self.phase = phase; self.parts = []; self.commits = []
    }

    public func validate(account: AccountKey? = nil) throws {
        guard LocalPath.isSafe(relativePath), source.url.isFileURL, source.size >= 0 else {
            throw UploadRecordError.invalid("上传源路径或大小无效")
        }
        if let remoteName {
            guard LocalPath.isSafe(remoteName), !remoteName.contains("/") else {
                throw UploadRecordError.invalid("上传远端名称无效")
            }
        }
        try expectation?.validate()
        if let expectation, expectation.size != source.size { throw UploadRecordError.invalid("源大小与校验基准不一致") }
        if let session {
            guard !session.id.isEmpty, session.partSize > 0, account == nil || session.account == account else {
                throw UploadRecordError.invalid("上传会话或账号不一致")
            }
        }
        if let preparation {
            guard preparation.fileID == id, account == nil || preparation.account == account,
                  preparation.source.identity.size == source.size,
                  expectation?.algorithm == .sha256,
                  expectation?.digest == preparation.source.sha256 else {
                throw UploadRecordError.invalid("上传准备记录与文件、账号或原始内容基准不一致")
            }
        }
        guard Set(parts.map(\.index)).count == parts.count else { throw UploadRecordError.invalid("分片回执重复") }
        var end: Int64 = 0
        let orderedParts = parts.sorted { $0.offset < $1.offset }
        for part in orderedParts {
            guard part.index >= 0, part.offset >= 0, part.length >= 0,
                  part.offset <= source.size, part.length <= source.size - part.offset,
                  part.offset >= end,
                  !part.serverReceipt.isEmpty, IntegrityExpectation.isDigest(part.sourceSHA256, algorithm: .sha256) else {
                throw UploadRecordError.invalid("分片回执范围或摘要无效")
            }
            end = part.offset + part.length
        }
        if phase == .failed, failedPhase == nil { throw UploadRecordError.invalid("失败文件缺少原阶段") }
        if phase == .completed, !isDirectory {
            guard expectation?.algorithm == .sha256, integrityRecordID != nil, remoteReference != nil else {
                throw UploadRecordError.invalid("已完成上传缺少原始 SHA-256、远端文件或校验记录")
            }
        }
        if let account {
            let references = commits.flatMap { [$0.stagingObject, $0.originalObject, $0.finalObject, $0.backupObject].compactMap { $0 } } + [remoteReference].compactMap { $0 }
            guard references.allSatisfy({ $0.provider == account.provider && !$0.identifier.isEmpty }) else {
                throw UploadRecordError.invalid("上传远端对象属于不同网盘")
            }
        }
    }
}

/// 在开始扫描前保存完整选择，进程中断后不能仅凭已扫描部分认定清单完成。
public struct UploadSelection: Codable, Sendable, Hashable {
    public let url: URL
    public let bookmark: Data

    public init(url: URL, bookmark: Data) throws {
        guard url.isFileURL, !bookmark.isEmpty else {
            throw UploadRecordError.invalid("上传选择必须包含本地路径和有效授权书签")
        }
        self.url = url; self.bookmark = bookmark
    }
}

/// 本轮完整回读的实时投影；不是可恢复摘要状态，暂停或取消后从零重新计算。
public struct UploadVerificationProgress: Sendable, Hashable {
    public let fileID: UUID
    public let relativePath: String
    public let verifiedBytes: Int64
    public let totalBytes: Int64

    public init(fileID: UUID, relativePath: String, verifiedBytes: Int64, totalBytes: Int64) {
        self.fileID = fileID; self.relativePath = relativePath
        self.verifiedBytes = verifiedBytes; self.totalBytes = totalBytes
    }
}

/// 批次仅保存聚合和清单 ID；UploadCoordinator 是唯一运行状态写入方。
public struct UploadJob: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let account: AccountKey
    public var accountName: String
    public var title: String
    public var destination: RemoteReference
    public var conflictPolicy: UploadConflictPolicy
    public var priority: Int
    public var isPaused: Bool
    public var cancellationRequested: Bool
    public var fileIDs: [UUID]
    /// nil 表示旧检查点未保存扫描根；恢复时应报告，不能猜测完整清单。
    public var selections: [UploadSelection]?
    /// 只有全部根项目扫描完并持久化后才写入；此前不能开始远端上传。
    public var scanCompletedAt: Date?
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var completedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var phase: UploadPhase
    public var error: String?
    public let createdAt: Date
    /// 仅由 coordinator 合并进列表快照，明确不写入检查点。
    public var verificationProgress: UploadVerificationProgress? = nil

    private enum CodingKeys: String, CodingKey {
        case id, account, accountName, title, destination, conflictPolicy, priority, isPaused, cancellationRequested
        case fileIDs, selections, scanCompletedAt, totalBytes, completedBytes, completedCount, failedCount, skippedCount
        case phase, error, createdAt
    }

    public init(id: UUID = UUID(), account: AccountKey, accountName: String, title: String,
                destination: RemoteReference, conflictPolicy: UploadConflictPolicy = .keepBoth,
                priority: Int = 0, createdAt: Date = .now) {
        self.id = id; self.account = account; self.accountName = accountName; self.title = title
        self.destination = destination; self.conflictPolicy = conflictPolicy; self.priority = priority
        self.isPaused = false; self.cancellationRequested = false; self.fileIDs = []
        self.totalBytes = 0; self.completedBytes = 0; self.completedCount = 0; self.failedCount = 0
        self.skippedCount = 0; self.phase = .preparing; self.createdAt = createdAt
    }

    public func validate() throws {
        if let selections {
            guard !selections.isEmpty,
                  selections.allSatisfy({ $0.url.isFileURL && !$0.bookmark.isEmpty }) else {
                throw UploadRecordError.invalid("上传批次原始选择或授权缺失")
            }
        }
        guard !account.accountID.isEmpty, !title.isEmpty, destination.provider == account.provider,
              !destination.identifier.isEmpty, Set(fileIDs).count == fileIDs.count,
              totalBytes >= 0, completedBytes >= 0, completedBytes <= totalBytes,
              completedCount >= 0, failedCount >= 0, skippedCount >= 0,
              completedCount <= fileIDs.count, failedCount <= fileIDs.count - completedCount,
              skippedCount <= fileIDs.count - completedCount - failedCount else {
            throw UploadRecordError.invalid("上传批次账号、目录、清单或聚合进度无效")
        }
    }
}

public enum TransferDirection: String, Codable, Sendable, Hashable { case upload, download }
public struct TransferTaskID: Codable, Sendable, Hashable {
    public let direction: TransferDirection
    public let id: UUID
    public init(direction: TransferDirection, id: UUID) { self.direction = direction; self.id = id }
}

/// 只读列表投影，不作为第二份执行状态落盘。
public struct TransferSnapshot: Sendable, Identifiable {
    public let id: TransferTaskID
    public let account: AccountKey?
    public let provider: Provider
    public let title: String
    public let phase: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let isPaused: Bool
    public let integrity: IntegrityStatus
    public let error: String?
    public init(id: TransferTaskID, account: AccountKey?, provider: Provider, title: String,
                phase: String, completedBytes: Int64, totalBytes: Int64, isPaused: Bool,
                integrity: IntegrityStatus, error: String? = nil) {
        self.id = id; self.account = account; self.provider = provider; self.title = title; self.phase = phase
        self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.isPaused = isPaused
        self.integrity = integrity; self.error = error
    }
}

public enum UploadRecordError: Error, LocalizedError, Sendable {
    case invalid(String)
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .unsupportedVersion(let version): "不支持的上传或校验记录格式版本：\(version)"
        }
    }
}
