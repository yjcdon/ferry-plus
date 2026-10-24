import Foundation

/// 两家网盘的轻量策略；调度层只处理公共文件和可持久化回执。
public protocol Netdisk: AnyObject, Sendable {
    var account: AccountKey { get }
    func openShare(_ link: DiskShareLink, password: String?) async throws -> DiskShareSession
    func listShare(_ session: DiskShareSession, directory: RemoteEntry?) async throws -> [RemoteEntry]
    func releaseShare(_ session: DiskShareSession) async
    func prepareTransfer(_ session: DiskShareSession, entries: [RemoteEntry]) async throws
    func listDirectory(_ directory: RemoteReference?) async throws -> [RemoteEntry]
    func createTransferDirectory(parentPath: String, name: String) async throws -> TransferDirectory
    func submitTransfer(_ session: DiskShareSession?, entries: [RemoteEntry], to directory: TransferDirectory,
                        previous: TransferProgress?,
                        onProgress: @Sendable (TransferProgress) async throws -> Void) async throws -> TransferProgress
    func deleteDirectory(_ directory: TransferDirectory) async throws
    /// 用户确认后将账号内一个准确对象移入回收站；请求只发送一次，未确认结果不得直接重发。
    func moveToTrash(entry: RemoteEntry, parent: RemoteReference, account: AccountKey) async throws
}

public enum NetdiskDeletionError: Error, LocalizedError, Sendable {
    case unsupported
    case invalidSelection
    case entryChanged
    case unconfirmed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "当前网盘未提供文件删除能力。"
        case .invalidSelection: "删除目标或父目录无效，不能删除网盘根目录。"
        case .entryChanged: "所选文件已不在原目录或身份发生变化，请刷新后重新选择。"
        case .unconfirmed(let reason): "删除结果尚未确认，请刷新目录核对后再操作：\(reason)"
        }
    }
}

public struct PreparedFile: Sendable {
    public let entry: RemoteEntry
    public let relativePath: String
}

extension Netdisk {
    public func releaseShare(_ session: DiskShareSession) async {}
    public func prepareTransfer(_ session: DiskShareSession, entries: [RemoteEntry]) async throws {}
    public func moveToTrash(entry: RemoteEntry, parent: RemoteReference, account: AccountKey) async throws {
        throw NetdiskDeletionError.unsupported
    }

    /// 写入前重新读取父目录，拒绝旧列表、另一账号、根目录和越界对象。
    func checkTrashSelection(entry: RemoteEntry, parent: RemoteReference, requestingAccount: AccountKey) async throws {
        guard requestingAccount == account, parent.provider == account.provider, entry.reference.provider == account.provider else {
            throw CoordinatorError.otherAccount
        }
        guard LocalPath.isSafe(entry.name), !entry.name.contains("/") else { throw NetdiskDeletionError.invalidSelection }
        switch entry.reference {
        case .baidu(let path, let fsID):
            guard fsID > 0, path.hasPrefix("/"), RemotePath.normalized(path) != "/",
                  LocalPath.isSafe(String(path.dropFirst())),
                  case .baidu(let parentPath, _) = parent,
                  let relative = RemotePath.relativePath(of: path, in: parentPath),
                  RemotePath.components(of: relative, omittingEmpty: false).count == 1,
                  RemotePath.isSameComponent(relative, entry.name) else { throw NetdiskDeletionError.invalidSelection }
        case .quark(let fid):
            guard !fid.isEmpty, fid != "0", !parent.identifier.isEmpty, fid != parent.identifier else {
                throw NetdiskDeletionError.invalidSelection
            }
        }
        try Task.checkCancellation()
        let children = try await listDirectory(parent)
        try validateChildren(children, of: parent)
        let matches = children.filter { $0.reference == entry.reference }
        guard matches.count == 1, let current = matches.first,
              current.name == entry.name, current.isDirectory == entry.isDirectory else { throw NetdiskDeletionError.entryChanged }
        try Task.checkCancellation()
    }

    /// 服务端回执后只做有限目录核对；索引延迟和查询失败不触发第二次删除。
    func confirmTrashRemoval(entry: RemoteEntry, parent: RemoteReference) async throws {
        do {
            for attempt in 0..<4 {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .milliseconds(200 << (attempt - 1))) }
                let children = try await listDirectory(parent)
                try validateChildren(children, of: parent)
                if !children.contains(where: { $0.reference == entry.reference }) { return }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NetdiskDeletionError.unconfirmed(error.localizedDescription)
        }
        throw NetdiskDeletionError.unconfirmed("原目录仍返回所选对象。")
    }
    /// 逐层读取所选目录；相同远端身份只处理一次，避免重复选择和循环目录耗尽资源。
    public func files(in entries: [RemoteEntry]) async throws -> [PreparedFile] {
        var pending = entries.reversed().map { ($0, $0.name) }
        var visited = Set<RemoteReference>()
        var result: [PreparedFile] = []
        while let (entry, relative) = pending.popLast() {
            try Task.checkCancellation()
            guard LocalPath.isSafe(relative), entry.reference.provider == account.provider else {
                throw TransferCheckError.unsafePath(relative)
            }
            if case .baidu(let path, _) = entry.reference {
                guard RemotePath.normalized(path) != "/" else { throw TransferCheckError.unsafePath(entry.name) }
                guard LocalPath.isSafe(String(path.dropFirst())) else {
                    throw TransferCheckError.unsafePath(path)
                }
            } else if entry.reference.identifier.isEmpty || entry.reference.identifier == "0" {
                throw TransferCheckError.unsafePath(entry.name)
            }
            guard visited.insert(entry.reference).inserted else { continue }
            if entry.isDirectory {
                let children = try await listDirectory(entry.reference)
                try validateChildren(children, of: entry.reference)
                for child in children.reversed() {
                    pending.append((child, relative + "/" + child.name))
                }
            } else { result.append(PreparedFile(entry: entry, relativePath: relative)) }
        }
        return result
    }

    /// 目录返回的文件身份必须位于本次请求的目录中。
    func validateChildren(_ children: [RemoteEntry], of reference: RemoteReference) throws {
        for child in children {
            guard child.reference.provider == reference.provider, LocalPath.isSafe(child.name), !child.name.contains("/") else {
                throw TransferCheckError.unsafePath(child.name)
            }
            if case .baidu(let parent, _) = reference {
                guard case .baidu(let path, _) = child.reference,
                      let nested = RemotePath.relativePath(of: path, in: parent),
                      RemotePath.components(of: nested, omittingEmpty: false).count == 1,
                      RemotePath.isSameComponent(nested, child.name) else {
                    throw TransferCheckError.outsideCheckedEntry(child.reference.identifier)
                }
            }
        }
    }
}
