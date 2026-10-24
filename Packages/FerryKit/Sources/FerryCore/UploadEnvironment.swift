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
    let resolve: @Sendable (RemoteReference, Int64) async throws -> ResolvedURL
    let inspectCommit: @Sendable (UploadCommit, UploadFile, RemoteReference) async throws -> UploadCommitInspection
    let releasePreparation: @Sendable (PreparedUpload) async throws -> Void

    public init(destination: any UploadDestination,
                listDirectory: @escaping @Sendable (RemoteReference) async throws -> [RemoteEntry],
                createDirectory: @escaping @Sendable (RemoteReference, String) async throws -> RemoteReference,
                resolve: @escaping @Sendable (RemoteReference, Int64) async throws -> ResolvedURL,
                inspectCommit: @escaping @Sendable (UploadCommit, UploadFile, RemoteReference) async throws -> UploadCommitInspection = { _, _, _ in .unconfirmed },
                releasePreparation: @escaping @Sendable (PreparedUpload) async throws -> Void = { _ in }) {
        self.destination = destination; self.listDirectory = listDirectory; self.createDirectory = createDirectory
        self.resolve = resolve; self.inspectCommit = inspectCommit
        self.releasePreparation = releasePreparation
    }
}

