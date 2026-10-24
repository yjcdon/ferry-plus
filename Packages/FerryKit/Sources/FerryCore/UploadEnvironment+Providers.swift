import Foundation
import BaiduKit
import QuarkKit
import DownloadKit

extension UploadEnvironment {
    /// 绑定当前百度会话；每次网络副作用前后检查会话身份，回读先核对准确 fs_id 和大小。
    public static func baidu(client: BaiduClient, account: AccountKey,
                             checkSession: @escaping @Sendable () async throws -> Void) throws -> UploadEnvironment {
        let destination = try BaiduUploadDestination(client: client, account: account)
        return UploadEnvironment(destination: destination, listDirectory: { reference in
            try await checkSession()
            let path = try baiduPath(reference)
            let entries = try await client.listDirectory(path).map(BaiduNetdisk.convert)
            try await checkSession()
            return entries
        }, createDirectory: { parent, name in
            try await checkSession()
            try validateName(name)
            let path = RemotePath.join(try baiduPath(parent), name)
            let entry = try await client.createOwnedDirectory(path)
            try await checkSession()
            return .baidu(path: entry.path, fsID: entry.fsID)
        }, resolve: { reference, size in
            try await checkSession()
            guard case .baidu(let path, let fsID) = reference, fsID > 0 else {
                throw UploadDestinationError.remoteResultUnconfirmed
            }
            let entries = try await client.listDirectory(RemotePath.parent(of: path))
            guard entries.contains(where: { $0.path == path && $0.fsID == fsID && !$0.isDirectory && $0.size == size }) else {
                throw UploadDestinationError.remoteResultUnconfirmed
            }
            let link = try await client.downloadLink(for: path)
            try await checkSession()
            return ResolvedURL(url: link.url, headers: link.headers)
        })
    }

    /// 绑定当前夸克会话；合并未知时只按预分配 fid 查询，不能认领同名文件或重新合并。
    public static func quark(client: QuarkClient, account: AccountKey, secrets: any UploadSecretStorage,
                             checkSession: @escaping @Sendable () async throws -> Void) throws -> UploadEnvironment {
        let destination = try QuarkUploadDestination(client: client, account: account, secrets: secrets)
        return UploadEnvironment(destination: destination, listDirectory: { reference in
            try await checkSession()
            let entries = try await client.listDirectory(parentFID: quarkFID(reference)).map { QuarkNetdisk.convert($0) }
            try await checkSession()
            return entries
        }, createDirectory: { parent, name in
            try await checkSession()
            try validateName(name)
            let fid = try await client.createDirectory(name: name, parentFID: quarkFID(parent))
            try await checkSession()
            return .quark(fid: fid)
        }, resolve: { reference, size in
            try await checkSession()
            let link = try await client.download(fid: quarkFID(reference))
            guard link.size == nil || link.size == size else { throw UploadDestinationError.remoteResultUnconfirmed }
            try await checkSession()
            return ResolvedURL(url: link.url, headers: link.headers)
        }, inspectCommit: { commit, file, parent in
            try await checkSession()
            guard commit.kind == .merge, let prepared = file.preparation, prepared.account == account else { return .unconfirmed }
            let native = try JSONDecoder().decode(QuarkUploadSession.self, from: prepared.nativeSession)
            guard native.parentFID == (try quarkFID(parent)) else { throw UploadDestinationError.invalidPreparation }
            let entries = try await client.listDirectory(parentFID: native.parentFID)
            try await checkSession()
            guard let entry = entries.first(where: { $0.fid == native.fileID }) else { return .unconfirmed }
            guard !entry.isDirectory, entry.size == native.size, entry.name == native.name else {
                return .rejected("预分配的夸克上传对象与文件基准不一致")
            }
            return .confirmed(.quark(fid: native.fileID))
        }, releasePreparation: { prepared in
            guard prepared.account == account else { throw UploadDestinationError.otherAccount }
            if let reference = prepared.secretReference { try await secrets.delete(reference: reference) }
        })
    }

    private static func validateName(_ name: String) throws {
        guard LocalPath.isSafe(name), !name.contains("/") else { throw UploadDestinationError.invalidName }
    }

    private static func baiduPath(_ reference: RemoteReference) throws -> String {
        guard case .baidu(let path, _) = reference, path.hasPrefix("/"),
              path == "/" || LocalPath.isSafe(String(path.dropFirst())) else { throw UploadDestinationError.otherAccount }
        return path
    }

    private static func quarkFID(_ reference: RemoteReference) throws -> String {
        guard case .quark(let fid) = reference, !fid.isEmpty else { throw UploadDestinationError.otherAccount }
        return fid
    }
}
