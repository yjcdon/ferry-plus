import Foundation
import QuarkKit

/// 夸克策略只在此处转换 fid、分享令牌和异步转存任务。
public actor QuarkNetdisk: Netdisk {
    public nonisolated let account: AccountKey
    private let client: QuarkClient
    private struct ShareState {
        let session: QuarkShareSession
        var entries: [String: QuarkEntry] = [:]
    }
    private var shares: [UUID: ShareState] = [:]

    public init(client: QuarkClient, account: AccountKey) { self.client = client; self.account = account }

    /// 每次打开取得独立短期会话，由窗口或转存流程结束时释放。
    public func openShare(_ link: DiskShareLink, password: String?) async throws -> DiskShareSession {
        guard link.provider == .quark else { throw CoordinatorError.otherAccount }
        let native = try await client.openShare(QuarkShareLink(id: link.code, passcode: password ?? link.password))
        let session = DiskShareSession(link: link, password: password ?? link.password, account: account, title: native.title)
        shares[session.handle] = ShareState(session: native)
        return session
    }
    public func releaseShare(_ session: DiskShareSession) { shares[session.handle] = nil }
    public func prepareTransfer(_ session: DiskShareSession, entries: [RemoteEntry]) async throws {
        guard session.account == account else { throw CoordinatorError.otherAccount }
        try await restoreShareEntries(session, entries: entries)
    }

    /// 原始分享文件令牌留在本适配器中，界面和任务只接收中立身份。
    public func listShare(_ session: DiskShareSession, directory: RemoteEntry?) async throws -> [RemoteEntry] {
        guard session.account == account, let state = shares[session.handle] else { throw CoordinatorError.otherAccount }
        let fid = try directory.map { try Self.fid($0.reference) } ?? "0"
        let entries = try await client.listShareDirectory(session: state.session, parentFID: fid)
        guard shares[session.handle] != nil else { throw QuarkError.invalidSelection }
        for entry in entries { shares[session.handle]?.entries[entry.fid] = entry }
        return entries.map(Self.convert)
    }

    public func listDirectory(_ directory: RemoteReference?) async throws -> [RemoteEntry] {
        let fid = try directory.map(Self.fid) ?? "0"
        return try await client.listDirectory(parentFID: fid).map(Self.convert)
    }

    /// 按配置路径逐层寻找或创建父目录，任务专用子目录始终使用新建返回的 fid。
    public func createTransferDirectory(parentPath: String, name: String) async throws -> TransferDirectory {
        let parts = parentPath.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw QuarkError.invalidSelection }
        var parent = "0"
        for part in parts {
            try Task.checkCancellation()
            let children = try await client.listDirectory(parentFID: parent)
            if let existing = children.first(where: { $0.name == part }) {
                guard existing.isDirectory else { throw QuarkError.invalidSelection }
                parent = existing.fid
            } else {
                do { parent = try await client.createDirectory(name: part, parentFID: parent) }
                catch {
                    // 同时创建任务可能竞争同一个配置父目录，重新确认真实目录身份后才复用。
                    let original = error
                    try Task.checkCancellation()
                    let refreshed = try await client.listDirectory(parentFID: parent)
                    guard let existing = refreshed.first(where: { $0.name == part && $0.isDirectory }) else { throw original }
                    parent = existing.fid
                }
            }
        }
        let siblings = try await client.listDirectory(parentFID: parent)
        guard !siblings.contains(where: { $0.name == name }) else { throw QuarkError.invalidSelection }
        let fid = try await client.createDirectory(name: name, parentFID: parent)
        guard !siblings.contains(where: { $0.fid == fid }) else { throw QuarkError.invalidResponse }
        return TransferDirectory(reference: .quark(fid: fid), name: name)
    }

    /// 提交回执立即交还调度器保存，不在此处等待服务端完成。
    public func submitTransfer(_ session: DiskShareSession, entries: [RemoteEntry], to directory: TransferDirectory) async throws -> TransferProgress {
        guard session.account == account, shares[session.handle] != nil else { throw CoordinatorError.otherAccount }
        let destination = try Self.fid(directory.reference)
        try Task.checkCancellation()
        guard let state = shares[session.handle] else { throw QuarkError.invalidSelection }
        let native = try entries.map { entry -> QuarkEntry in
            let fid = try Self.fid(entry.reference)
            guard let original = state.entries[fid] else { throw QuarkError.invalidSelection }
            return original
        }
        let taskID = try await client.submitSave(session: state.session, entries: native, destinationFID: destination)
        return TransferProgress(taskID: taskID, submitted: true)
    }

    /// 重启后旧任务只有 fid；按当前分享重新寻找所选项，令牌不从任务数据恢复。
    private func restoreShareEntries(_ session: DiskShareSession, entries: [RemoteEntry]) async throws {
        guard let state = shares[session.handle] else { throw QuarkError.invalidSelection }
        let required = Set(try entries.map { try Self.fid($0.reference) })
        var missing = required.subtracting(state.entries.keys)
        guard !missing.isEmpty else { return }
        var pending = ["0"]
        var visited = Set<String>()
        while !missing.isEmpty, let parent = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(parent).inserted else { continue }
            let children = try await client.listShareDirectory(session: state.session, parentFID: parent)
            guard shares[session.handle] != nil else { throw QuarkError.invalidSelection }
            for child in children {
                if missing.remove(child.fid) != nil { shares[session.handle]?.entries[child.fid] = child }
                if child.isDirectory, !visited.contains(child.fid) { pending.append(child.fid) }
            }
        }
        guard missing.isEmpty else { throw QuarkError.invalidSelection }
    }

    /// 重启后可直接使用持久化的任务 ID 重新核对，不依赖旧分享令牌。
    public func waitForTransfer(_ progress: TransferProgress) async throws -> TransferProgress {
        if progress.completed { return progress }
        guard progress.submitted, let taskID = progress.taskID else { throw TransferCheckError.unconfirmedTransfer }
        _ = try await client.waitForTask(id: taskID)
        return TransferProgress(taskID: taskID, submitted: true, completed: true)
    }

    public func deleteDirectory(_ directory: TransferDirectory) async throws {
        try await client.delete(fids: [Self.fid(directory.reference)])
    }

    private static func fid(_ reference: RemoteReference) throws -> String {
        guard case .quark(let fid) = reference else { throw CoordinatorError.otherAccount }
        return fid
    }
    public nonisolated static func convert(_ entry: QuarkEntry) -> RemoteEntry {
        RemoteEntry(reference: .quark(fid: entry.fid), name: entry.name, isDirectory: entry.isDirectory,
            size: entry.size, modifiedAt: entry.updatedAt, md5: entry.md5)
    }
}
