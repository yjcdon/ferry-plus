import Foundation
import QuarkKit

/// 夸克策略只在此处转换 fid、分享令牌和异步转存任务。
public actor QuarkNetdisk: Netdisk {
    public nonisolated let account: AccountKey
    private let client: QuarkClient
    private struct ShareState {
        let session: QuarkShareSession
        var entries: [String: QuarkEntry] = [:]
        var relativeDirectories: [String: String] = [:]
        var directoryListings: [String: [QuarkEntry]] = [:]
        var listingPaths: [String: String] = [:]
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
        let parentPath: String
        if let directory {
            if directory.relativeDirectory == nil, state.relativeDirectories[fid] == nil {
                try await restoreShareEntries(session, entries: [directory])
            }
            guard let parent = directory.relativeDirectory ?? shares[session.handle]?.relativeDirectories[fid] else { throw QuarkError.invalidSelection }
            parentPath = Self.join(parent, directory.name)
        } else { parentPath = "" }
        let entries = try await shareChildren(session, parentFID: fid, relativePath: parentPath)
        return entries.map { Self.convert($0, relativeDirectory: parentPath) }
    }

    public func listDirectory(_ directory: RemoteReference?) async throws -> [RemoteEntry] {
        let fid = try directory.map(Self.fid) ?? "0"
        return try await client.listDirectory(parentFID: fid).map { Self.convert($0) }
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

    /// 每个相对目录独立记录意图、回执与完成；未知提交不重复发送，未提交组可以安全继续。
    public func submitTransfer(_ session: DiskShareSession?, entries: [RemoteEntry], to directory: TransferDirectory,
                               previous: TransferProgress?,
                               onProgress: @Sendable (TransferProgress) async throws -> Void) async throws -> TransferProgress {
        if let previous, previous.completed { return previous }
        let root = try Self.fid(directory.reference)
        guard !root.isEmpty, root != "0", !entries.isEmpty,
              entries.allSatisfy({ $0.reference.provider == .quark }) else { throw QuarkError.invalidSelection }
        // 升级前只有一个回执的任务沿用原结果，不将已提交任务重新规划成多个 POST。
        if let previous, previous.batches == nil, previous.submitted {
            guard let taskID = previous.taskID else { throw TransferCheckError.unconfirmedTransfer }
            _ = try await client.waitForTask(id: taskID)
            let completed = TransferProgress(taskID: taskID, submitted: true, completed: true)
            try await onProgress(completed)
            return completed
        }
        var batches: [TransferBatchProgress]
        if let saved = previous?.batches {
            let selected = Set(entries.map(\.id))
            let ids = saved.flatMap(\.entryIDs)
            guard !saved.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: selected),
                  Set(saved.map(\.relativeDirectory)).count == saved.count,
                  saved.allSatisfy({ !$0.entryIDs.isEmpty && Self.safeDirectory($0.relativeDirectory) }) else { throw QuarkError.invalidSelection }
            batches = saved
        } else {
            guard let session, session.account == account, let state = shares[session.handle] else { throw CoordinatorError.otherAccount }
            let located = try entries.map { entry -> (RemoteEntry, String) in
                guard let path = state.relativeDirectories[try Self.fid(entry.reference)], Self.safeDirectory(path) else { throw QuarkError.invalidSelection }
                return (entry, path)
            }
            let selectedDirectories = Set(located.filter { $0.0.isDirectory }.map { Self.join($0.1, $0.0.name) })
            let topLevel = located.filter { _, parent in
                var cursor = parent
                while !cursor.isEmpty {
                    if selectedDirectories.contains(cursor) { return false }
                    cursor = cursor.split(separator: "/").dropLast().joined(separator: "/")
                }
                return true
            }
            let groups = Dictionary(grouping: topLevel, by: { $0.1 })
            batches = groups.keys.sorted().map { path in
                TransferBatchProgress(relativeDirectory: path, entryIDs: groups[path]!.map { $0.0.id }.sorted())
            }
            try await onProgress(Self.progress(batches))
        }
        for index in batches.indices {
            try Task.checkCancellation()
            if batches[index].completed { continue }
            if !batches[index].submitted {
                guard let session, session.account == account, let state = shares[session.handle] else { throw CoordinatorError.otherAccount }
                let target = try await destination(root: root, relativeDirectory: batches[index].relativeDirectory,
                                                   recorded: batches[index].destination)
                batches[index].destination = .quark(fid: target)
                try await onProgress(Self.progress(batches))
                let native = try batches[index].entryIDs.map { fid -> QuarkEntry in
                    guard let entry = state.entries[fid], state.relativeDirectories[fid] == batches[index].relativeDirectory else { throw QuarkError.invalidSelection }
                    return entry
                }
                try Task.checkCancellation()
                batches[index].submitted = true
                try await onProgress(Self.progress(batches))
                let taskID = try await client.submitSave(session: state.session, entries: native, destinationFID: target,
                    parentFID: batches[index].relativeDirectory.isEmpty ? "0" : (native.first?.parentFID ?? "0"))
                batches[index].taskID = taskID
                try await onProgress(Self.progress(batches))
            }
            guard let taskID = batches[index].taskID else { throw TransferCheckError.unconfirmedTransfer }
            _ = try await client.waitForTask(id: taskID)
            batches[index].completed = true
            try await onProgress(Self.progress(batches))
        }
        return Self.progress(batches)
    }

    /// 所有子目录均从任务拥有的根 fid 开始逐层解析，保存的目的身份必须仍与该路径一致。
    private func destination(root: String, relativeDirectory: String, recorded: RemoteReference?) async throws -> String {
        guard Self.safeDirectory(relativeDirectory) else { throw QuarkError.invalidSelection }
        var parent = root
        for component in relativeDirectory.split(separator: "/") {
            try Task.checkCancellation()
            let name = String(component)
            let children = try await client.listDirectory(parentFID: parent)
            if let existing = children.first(where: { $0.name == name }) {
                guard existing.isDirectory else { throw QuarkError.invalidSelection }
                parent = existing.fid
            } else {
                guard recorded == nil else { throw QuarkError.invalidSelection }
                parent = try await client.createDirectory(name: name, parentFID: parent)
            }
        }
        if let recorded, try Self.fid(recorded) != parent { throw QuarkError.invalidSelection }
        return parent
    }

    private static func progress(_ batches: [TransferBatchProgress]) -> TransferProgress {
        TransferProgress(submitted: batches.allSatisfy(\.submitted), completed: batches.allSatisfy(\.completed), batches: batches)
    }
    private static func safeDirectory(_ path: String) -> Bool { path.isEmpty || LocalPath.isSafe(path) }
    private static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    /// 已记录路径时只沿相关前缀恢复令牌；只有缺少路径的旧任务才扫描分享树。
    private func restoreShareEntries(_ session: DiskShareSession, entries: [RemoteEntry]) async throws {
        try Task.checkCancellation()
        guard let state = shares[session.handle] else { throw QuarkError.invalidSelection }
        var unresolved: [RemoteEntry] = []
        for entry in entries {
            let fid = try Self.fid(entry.reference)
            if let native = state.entries[fid] {
                if let path = entry.relativeDirectory, state.relativeDirectories[fid] != path { throw QuarkError.invalidSelection }
                guard native.name == entry.name, native.isDirectory == entry.isDirectory else { throw QuarkError.invalidSelection }
            } else { unresolved.append(entry) }
        }
        let groups = Dictionary(grouping: unresolved.filter { $0.relativeDirectory != nil }, by: { $0.relativeDirectory! })
        for path in groups.keys.sorted() {
            guard Self.safeDirectory(path) else { throw QuarkError.invalidSelection }
            var parentFID = "0"
            var parentPath = ""
            for component in path.split(separator: "/") {
                let children = try await shareChildren(session, parentFID: parentFID, relativePath: parentPath)
                guard let directory = children.first(where: { $0.isDirectory && $0.name == component }) else { throw QuarkError.invalidSelection }
                parentFID = directory.fid
                parentPath = Self.join(parentPath, String(component))
            }
            let children = try await shareChildren(session, parentFID: parentFID, relativePath: path)
            let byID = Dictionary(uniqueKeysWithValues: children.map { ($0.fid, $0) })
            for selected in groups[path]! {
                guard let native = byID[selected.id], native.name == selected.name,
                      native.isDirectory == selected.isDirectory else { throw QuarkError.invalidSelection }
            }
        }
        // 旧记录没有 relativeDirectory，无法从 fid 推断父目录，才使用可取消的兼容扫描。
        guard let restored = shares[session.handle] else { throw QuarkError.invalidSelection }
        var missing = Set(unresolved.filter { $0.relativeDirectory == nil }.map(\.id)).subtracting(restored.entries.keys)
        var pending = [("0", "")]
        var visited = Set<String>()
        while !missing.isEmpty, let (parent, path) = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(parent).inserted else { continue }
            let children = try await shareChildren(session, parentFID: parent, relativePath: path)
            for child in children {
                missing.remove(child.fid)
                if child.isDirectory, !visited.contains(child.fid) { pending.append((child.fid, Self.join(path, child.name))) }
            }
        }
        guard missing.isEmpty else { throw QuarkError.invalidSelection }
        guard let finalState = shares[session.handle] else { throw QuarkError.invalidSelection }
        for entry in unresolved where entry.relativeDirectory == nil {
            guard let native = finalState.entries[entry.id], native.name == entry.name,
                  native.isDirectory == entry.isDirectory else { throw QuarkError.invalidSelection }
        }
    }

    /// 会话内复用每层完整目录，路径与 fid 同时核对，释放会话后迟到请求不能恢复缓存。
    private func shareChildren(_ session: DiskShareSession, parentFID: String, relativePath: String) async throws -> [QuarkEntry] {
        try Task.checkCancellation()
        guard let state = shares[session.handle], Self.safeDirectory(relativePath) else { throw QuarkError.invalidSelection }
        if let cached = state.directoryListings[parentFID] {
            guard state.listingPaths[parentFID] == relativePath else { throw QuarkError.invalidSelection }
            return cached
        }
        let children = try await client.listShareDirectory(session: state.session, parentFID: parentFID)
        try Task.checkCancellation()
        guard shares[session.handle] != nil else { throw QuarkError.invalidSelection }
        shares[session.handle]?.directoryListings[parentFID] = children
        shares[session.handle]?.listingPaths[parentFID] = relativePath
        for child in children {
            shares[session.handle]?.entries[child.fid] = child
            shares[session.handle]?.relativeDirectories[child.fid] = relativePath
        }
        return children
    }

    public func deleteDirectory(_ directory: TransferDirectory) async throws {
        try await client.delete(fids: [Self.fid(directory.reference)])
    }

    private static func fid(_ reference: RemoteReference) throws -> String {
        guard case .quark(let fid) = reference else { throw CoordinatorError.otherAccount }
        return fid
    }
    public nonisolated static func convert(_ entry: QuarkEntry, relativeDirectory: String? = nil) -> RemoteEntry {
        RemoteEntry(reference: .quark(fid: entry.fid), name: entry.name, isDirectory: entry.isDirectory,
            size: entry.size, modifiedAt: entry.updatedAt, md5: entry.md5, relativeDirectory: relativeDirectory)
    }
}
