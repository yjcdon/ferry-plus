import Foundation
import DownloadKit

public enum UploadCommitInspection: Sendable {
    case confirmed(RemoteReference)
    case unconfirmed
    case rejected(String)
}
/// 当前账号绑定的上传环境；查询回执必须证明准确对象，不能仅凭同名同大小认领文件。
public struct UploadEnvironment: Sendable {
    public let destination: any UploadDestination
    let listDirectory: @Sendable (RemoteReference) async throws -> [RemoteEntry]
    let createDirectory: @Sendable (RemoteReference, String) async throws -> RemoteReference
    let createDirectoryWithCheckpoint: (@Sendable (RemoteReference, String, @Sendable (RemoteReference) async throws -> Void) async throws -> RemoteReference)?
    let resolve: @Sendable (RemoteReference, Int64) async throws -> ResolvedURL
    let inspectCommit: @Sendable (UploadCommit, UploadFile, RemoteReference) async throws -> UploadCommitInspection
    /// 查询原预分配对象；未找到只表示结果未确认，不表示对象权威不存在。
    let inspectPreparedResult: @Sendable (PreparedUpload, RemoteReference) async throws -> UploadCommitInspection
    let releasePreparation: @Sendable (PreparedUpload) async throws -> Void

    /// 在绑定账号的准确父目录下新建目录；失败可能已产生远端副作用，调用方不得自动重试。
    public func makeDirectory(parent: RemoteReference, name: String) async throws -> RemoteReference {
        try await createDirectory(parent, name)
    }

    /// 准确创建回执先交给调用方持久化，再执行创建环境的后置会话核对。
    /// 旧注入环境在返回后补交回执，保持既有初始化和目录选择入口兼容。
    public func makeDirectory(parent: RemoteReference, name: String,
                              onCreated: @Sendable (RemoteReference) async throws -> Void) async throws -> RemoteReference {
        if let createDirectoryWithCheckpoint { return try await createDirectoryWithCheckpoint(parent, name, onCreated) }
        let reference = try await createDirectory(parent, name)
        try await onCreated(reference)
        return reference
    }

    public init(destination: any UploadDestination,
                listDirectory: @escaping @Sendable (RemoteReference) async throws -> [RemoteEntry],
                createDirectory: @escaping @Sendable (RemoteReference, String) async throws -> RemoteReference,
                resolve: @escaping @Sendable (RemoteReference, Int64) async throws -> ResolvedURL,
                inspectCommit: @escaping @Sendable (UploadCommit, UploadFile, RemoteReference) async throws -> UploadCommitInspection = { _, _, _ in .unconfirmed },
                releasePreparation: @escaping @Sendable (PreparedUpload) async throws -> Void = { _ in },
                inspectPreparedResult: @escaping @Sendable (PreparedUpload, RemoteReference) async throws -> UploadCommitInspection = { _, _ in .unconfirmed },
                createDirectoryWithCheckpoint: (@Sendable (RemoteReference, String, @Sendable (RemoteReference) async throws -> Void) async throws -> RemoteReference)? = nil) {
        self.destination = destination; self.listDirectory = listDirectory; self.createDirectory = createDirectory
        self.resolve = resolve; self.inspectCommit = inspectCommit
        self.releasePreparation = releasePreparation
        self.inspectPreparedResult = inspectPreparedResult
        self.createDirectoryWithCheckpoint = createDirectoryWithCheckpoint
    }
}

