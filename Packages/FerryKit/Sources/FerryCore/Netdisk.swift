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
}

public struct PreparedFile: Sendable {
    public let entry: RemoteEntry
    public let relativePath: String
}

extension Netdisk {
    public func releaseShare(_ session: DiskShareSession) async {}
    public func prepareTransfer(_ session: DiskShareSession, entries: [RemoteEntry]) async throws {}
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
