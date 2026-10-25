import Foundation
import BaiduKit
import DownloadKit

/// 百度安全发布的路径操作策略；写回执只确认请求，准确对象及内容由发布器另行核对。
public struct BaiduUploadReplacementDestination: UploadReplacementDestination {
    public let account: AccountKey
    private let client: BaiduClient
    private let checkSession: @Sendable () async throws -> Void

    public init(client: BaiduClient, account: AccountKey,
                checkSession: @escaping @Sendable () async throws -> Void) throws {
        guard account.provider == .baidu else { throw UploadDestinationError.otherAccount }
        self.client = client; self.account = account; self.checkSession = checkSession
    }

    /// 在已绑定父目录中查询唯一名称；重复匹配属于无法确认的响应，不任意选择其一。
    public func find(parent: RemoteReference, name: String) async throws -> RemoteEntry? {
        try await checkSession()
        let entries = try await client.listDirectory(path(parent))
        try await checkSession()
        let matches = entries.filter { RemotePath.isSameComponent($0.name, name) }
        guard matches.count <= 1 else { throw UploadDestinationError.remoteResultUnconfirmed }
        return matches.first.map(BaiduNetdisk.convert)
    }

    /// 回读之前核对准确 fs_id、路径及大小，避免短期地址按名称读到另一个版本。
    public func resolve(reference: RemoteReference, size: Int64) async throws -> ResolvedURL {
        try await checkSession()
        guard case .baidu(let objectPath, let fsID) = reference, fsID > 0 else {
            throw UploadDestinationError.otherAccount
        }
        let entries = try await client.listDirectory(RemotePath.parent(of: objectPath))
        guard entries.contains(where: { $0.fsID == fsID && $0.path == objectPath && !$0.isDirectory && $0.size == size }) else {
            throw UploadDestinationError.remoteResultUnconfirmed
        }
        let link = try await client.downloadLink(for: objectPath)
        try await checkSession()
        return ResolvedURL(url: link.url, headers: link.headers)
    }

    /// 服务端复制生成独立旧字节快照；目标不允许覆盖，后置查询失败不能触发重发。
    public func copy(source: RemoteReference, newName: String) async throws {
        try await checkSession()
        let sourcePath = try path(source)
        try await client.copyWithoutReplacing(path: sourcePath,
            destinationDirectory: RemotePath.parent(of: sourcePath), newName: newName)
        try await checkSession()
    }

    /// 在写意图之前只读检查旧版本快照空间；检查失败不产生“请求已发出”的检查点。
    public func checkSnapshotCapacity(size: Int64) async throws {
        try await checkSession()
        let capacity = try await client.capacity()
        guard size >= 0, max(0, capacity.total - capacity.used) >= size else {
            throw UploadRecordError.invalid("网盘剩余空间不足以保留独立旧版本备份")
        }
        try await checkSession()
    }

    /// 按当前路径绑定改名；不假定服务端支持版本条件，发布器须核对实际被移动的对象。
    public func rename(source: RemoteReference, newName: String) async throws {
        try await checkSession()
        try await client.renameWithoutReplacing(path: path(source), newName: newName)
        try await checkSession()
    }

    private func path(_ reference: RemoteReference) throws -> String {
        guard case .baidu(let path, _) = reference else { throw UploadDestinationError.otherAccount }
        return path
    }
}
