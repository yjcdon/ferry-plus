import BaiduKit
import Foundation

/// 百度专属类型只在适配边界转换；分享句柄不落盘。
public actor BaiduNetdisk: Netdisk {
    public nonisolated let account: AccountKey
    private let client: BaiduClient
    private var shares: [UUID: ShareSession] = [:]
    public init(client: BaiduClient, account: AccountKey) { self.client = client; self.account = account }

    public func openShare(_ link: DiskShareLink, password: String?) async throws -> DiskShareSession {
        guard link.provider == .baidu, let native = BaiduKit.ShareLink(surl: link.code, password: password ?? link.password) else {
            throw BaiduError.invalidShareLink
        }
        let share = try await client.openShare(native, password: password)
        let session = DiskShareSession(link: link, password: share.password, account: account, title: "百度分享")
        shares[session.handle] = share
        return session
    }
    public func releaseShare(_ session: DiskShareSession) { shares[session.handle] = nil }
    public func listShare(_ session: DiskShareSession, directory: RemoteEntry?) async throws -> [RemoteEntry] {
        guard let share = shares[session.handle], session.account == account else { throw CoordinatorError.otherAccount }
        return try await client.listShare(share, directory: directory.map(Self.shareEntry)).map(Self.convert)
    }
    public func listDirectory(_ directory: RemoteReference?) async throws -> [RemoteEntry] {
        let path: String
        if let directory {
            guard case .baidu(let value, _) = directory else { throw CoordinatorError.otherAccount }
            path = value
        } else { path = "/" }
        return try await client.listDirectory(path).map(Self.convert)
    }
    public func createTransferDirectory(parentPath: String, name: String) async throws -> TransferDirectory {
        let path = RemotePath.join(RemotePath.normalized(parentPath), name)
        if RemotePath.normalized(parentPath) != "/" { try await client.createDirectory(RemotePath.normalized(parentPath)) }
        let entry = try await client.createOwnedDirectory(path)
        return TransferDirectory(reference: .baidu(path: path, fsID: entry.fsID), name: name)
    }
    public func submitTransfer(_ session: DiskShareSession?, entries: [RemoteEntry], to directory: TransferDirectory,
                               previous: TransferProgress?,
                               onProgress: @Sendable (TransferProgress) async throws -> Void) async throws -> TransferProgress {
        if let previous, previous.completed { return previous }
        guard previous?.submitted != true else { throw TransferCheckError.unconfirmedTransfer }
        guard let session, let share = shares[session.handle], session.account == account,
              case .baidu(let path, _) = directory.reference else { throw CoordinatorError.otherAccount }
        try await onProgress(TransferProgress(submitted: true))
        try await client.transfer(share, entries: entries.map(Self.shareEntry), to: path)
        let progress = TransferProgress(submitted: true, completed: true)
        try await onProgress(progress)
        return progress
    }
    public func deleteDirectory(_ directory: TransferDirectory) async throws {
        guard case .baidu(let path, let fsID) = directory.reference, fsID > 0 else { throw TransferCheckError.missingJobDirectory }
        let siblings = try await client.listDirectory(RemotePath.parent(of: path))
        guard siblings.contains(where: { $0.fsID == fsID && $0.path == path && $0.isDirectory }) else {
            throw TransferCheckError.missingJobDirectory
        }
        try Task.checkCancellation()
        try await client.delete(paths: [path])
    }

    /// 仅复用已核对 path 与 fsID 的账号对象；PCS 删除将文件或文件夹移入百度回收站。
    public func moveToTrash(entry: RemoteEntry, parent: RemoteReference, account requestingAccount: AccountKey) async throws {
        try await checkTrashSelection(entry: entry, parent: parent, requestingAccount: requestingAccount)
        guard case .baidu(let path, _) = entry.reference else { throw CoordinatorError.otherAccount }
        try await client.delete(paths: [path])
        try await confirmTrashRemoval(entry: entry, parent: parent)
    }
    private static func shareEntry(_ entry: RemoteEntry) throws -> ShareEntry {
        guard case .baidu(let path, let fsID) = entry.reference else { throw CoordinatorError.otherAccount }
        return ShareEntry(fsID: fsID, name: entry.name, path: path, isDirectory: entry.isDirectory, size: entry.size, relativeDirectory: entry.relativeDirectory ?? "")
    }
    public nonisolated static func convert(_ entry: ShareEntry) -> RemoteEntry {
        RemoteEntry(reference: .baidu(path: entry.path, fsID: entry.fsID), name: entry.name, isDirectory: entry.isDirectory, size: entry.size, relativeDirectory: entry.relativeDirectory)
    }
    public nonisolated static func convert(_ entry: NetdiskEntry) -> RemoteEntry {
        RemoteEntry(reference: .baidu(path: entry.path, fsID: entry.fsID), name: entry.name, isDirectory: entry.isDirectory, size: entry.size, modifiedAt: entry.modifiedAt)
    }
}
