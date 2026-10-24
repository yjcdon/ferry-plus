import BaiduKit
import DownloadKit
import Foundation
import os
import QuarkKit
import Testing
@testable import FerryCore

/// 内存中的假网盘。分享内容按相对路径保存；转存把它们复制到网盘路径下。自己网盘中的文件按网盘路径保存。
final class FakeNetdisk: Netdisk {
    enum Operation: Equatable {
        case openShare
        case createDirectory(String)
        case transfer(String)
        case list(String)
        case listDirectory(String)
        case delete([String])
    }

    private struct State {
        var beforeShareOpen: (@Sendable () throws -> Void)?
        var share: [String: Data] = [:]
        /// 分享中没有文件的目录（相对路径）。
        var emptyDirectories: Set<String> = []
        var disk: [String: Data] = [:]
        /// 下一次列目录返回这个结果，模拟转存后列表还没更新或返回了意外的路径。
        var nextListing: [RemoteFile]?
        var operations: [Operation] = []
        var transferFailures = 0
        var listFailures = 0
        var deleteFailures = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    let account: AccountKey

    private init(state: OSAllocatedUnfairLock<State>, account: AccountKey) {
        self.state = state
        self.account = account
    }

    func withAccount(_ id: Int64) -> FakeNetdisk {
        FakeNetdisk(state: state, account: AccountKey(provider: .baidu, accountID: String(id)))
    }

    /// - Parameter disk: 自己网盘中原来就有的文件，键是网盘路径。
    init(share: [String: Data], emptyDirectories: Set<String> = [], disk: [String: Data] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State())
        account = AccountKey(provider: .baidu, accountID: "1")
        state.withLock {
            $0.share = share
            $0.emptyDirectories = emptyDirectories
            $0.disk = disk
        }
    }

    var operations: [Operation] { state.withLock { $0.operations } }
    func beforeNextShareOpen(_ action: @escaping @Sendable () throws -> Void) {
        state.withLock { $0.beforeShareOpen = action }
    }
    func data(at path: String) -> Data? { state.withLock { $0.disk[path] } }
    func remotePaths() -> [String] { state.withLock { $0.disk.keys.sorted() } }

    /// 下一次转存复制一个条目后失败，模拟转存到一半中断。
    func failNextTransfer() { state.withLock { $0.transferFailures += 1 } }
    func failNextDelete() { state.withLock { $0.deleteFailures += 1 } }
    /// 下一次递归列出失败。
    func failNextList() { state.withLock { $0.listFailures += 1 } }
    /// 收到的删除操作。网盘任务的测试要求它一直为空。
    var deletes: [[String]] {
        operations.compactMap { if case .delete(let paths) = $0 { paths } else { nil } }
    }
    func setNextListing(_ files: [RemoteFile]) { state.withLock { $0.nextListing = files } }

    func openShare(_ link: DiskShareLink, password: String?) async throws -> DiskShareSession {
        let action = state.withLock { state in
            state.operations.append(.openShare)
            defer { state.beforeShareOpen = nil }
            return state.beforeShareOpen
        }
        try action?()
        return Self.session
    }

    func createDirectory(_ path: String) async throws {
        state.withLock { $0.operations.append(.createDirectory(path)) }
    }

    func transfer(_ session: DiskShareSession, entries: [RemoteEntry], to directory: String) async throws {
        try state.withLock { state in
            state.operations.append(.transfer(directory))
            let shouldFail = state.transferFailures > 0
            state.transferFailures = max(0, state.transferFailures - 1)
            for entry in entries {
                let matches = state.share.filter { $0.key == entry.relativePath || $0.key.hasPrefix(entry.relativePath + "/") }
                for (path, data) in matches {
                    let target = directory + "/" + path
                    // 真实接口遇到同名条目时返回 -30。
                    guard state.disk[target] == nil else { throw BaiduError.transferConflict(name: entry.name) }
                    state.disk[target] = data
                }
                if shouldFail { throw BaiduError.network("connection lost") }
            }
        }
    }

    func listShare(_ session: DiskShareSession, directory: RemoteEntry?) async throws -> [RemoteEntry] {
        let prefix = directory.map { $0.relativePath + "/" } ?? ""
        return entries(under: prefix)
    }

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        state.withLock { state in
            state.operations.append(.listDirectory(path))
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let names = Set(state.disk.keys.filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
            return names.sorted().map { name in
                let child = prefix + name
                let data = state.disk[child]
                return RemoteEntry(fsID: Int64(child.hashValue), name: name, path: child, isDirectory: data == nil,
                                    size: Int64(data?.count ?? 0))
            }
        }
    }

    func listFilesRecursively(_ path: String) async throws -> [RemoteFile] {
        try state.withLock { state in
            state.operations.append(.list(path))
            if state.listFailures > 0 {
                state.listFailures -= 1
                throw BaiduError.network("connection lost")
            }
            if let listing = state.nextListing {
                state.nextListing = nil
                return listing
            }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return state.disk.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                .enumerated().map { RemoteFile(path: $1.key, size: Int64($1.value.count), fsID: Int64($0)) }
        }
    }

    func delete(paths: [String]) async throws {
        try state.withLock { state in
            state.operations.append(.delete(paths))
            if state.deleteFailures > 0 {
                state.deleteFailures -= 1
                throw BaiduError.tryLater
            }
            for path in paths {
                state.disk = state.disk.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            }
        }
    }

    func createTransferDirectory(parentPath: String, name: String) async throws -> TransferDirectory {
        let path = RemotePath.join(parentPath, name)
        try await createDirectory(path)
        return TransferDirectory(reference: .baidu(path: path, fsID: 0), name: name)
    }

    func submitTransfer(_ session: DiskShareSession?, entries: [RemoteEntry], to directory: TransferDirectory,
                        previous: TransferProgress?,
                        onProgress: @Sendable (TransferProgress) async throws -> Void) async throws -> TransferProgress {
        if let previous, previous.completed { return previous }
        guard previous?.submitted != true, let session else { throw TransferCheckError.unconfirmedTransfer }
        try await onProgress(TransferProgress(submitted: true))
        try await transfer(session, entries: entries, to: directory.reference.identifier)
        let progress = TransferProgress(submitted: true, completed: true)
        try await onProgress(progress)
        return progress
    }

    func deleteDirectory(_ directory: TransferDirectory) async throws {
        try await delete(paths: [directory.reference.identifier])
    }

    func listDirectory(_ directory: RemoteReference?) async throws -> [RemoteEntry] {
        let path = directory?.identifier ?? "/"
        return try state.withLock { state in
            state.operations.append(.list(path))
            if state.listFailures > 0 {
                state.listFailures -= 1
                throw BaiduError.network("connection lost")
            }
            if let listing = state.nextListing {
                state.nextListing = nil
                return listing.map {
                    RemoteEntry(fsID: $0.fsID, name: String($0.path.split(separator: "/").last ?? ""),
                                path: $0.path, isDirectory: false, size: $0.size)
                }
            }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let names = Set(state.disk.keys.filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
            return names.sorted().map { name in
                let child = prefix + name
                let data = state.disk[child]
                return RemoteEntry(fsID: Int64(child.hashValue), name: name, path: child,
                                   isDirectory: data == nil, size: Int64(data?.count ?? 0))
            }
        }
    }

    static let link = DiskShareLink.parse("https://pan.baidu.com/s/1qYZEsSc")!
    static let session = DiskShareSession(link: link, password: nil, account: AccountKey(provider: .baidu, accountID: "1"), title: "Test share")

    /// 分享根目录中的条目。
    func rootEntries() -> [RemoteEntry] {
        entries(under: "")
    }

    /// `prefix` 为空或以 `/` 结尾的相对目录。
    private func entries(under prefix: String) -> [RemoteEntry] {
        let (share, emptyDirectories) = state.withLock { ($0.share, $0.emptyDirectories) }
        let paths = Array(share.keys) + Array(emptyDirectories)
        let names = Set(paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
        let directory = String(prefix.dropLast())
        return names.sorted().enumerated().map { index, name in
            let path = prefix + name
            let isDirectory = share[path] == nil
            return RemoteEntry(fsID: Int64(path.hashValue), name: name, path: "/share/" + path, isDirectory: isDirectory,
                              size: Int64(share[path]?.count ?? 0), relativeDirectory: directory)
        }
    }
}

/// 按网盘路径提供文件内容的 HTTP 桩。每个实例用自己的 host，并行测试互不干扰。
final class FileServer: Sendable {
    let host = "\(UUID().uuidString.lowercased()).test"
    private let netdisk: FakeNetdisk
    private let state = OSAllocatedUnfairLock<(log: [String], stalled: Bool, failing: Set<String>, stalling: Set<String>)>(initialState: ([], false, [], []))

    init(netdisk: FakeNetdisk) {
        self.netdisk = netdisk
        FileProtocol.register(self, host: host)
    }

    private let resolveLog = OSAllocatedUnfairLock<[String]>(initialState: [])

    var log: [String] { state.withLock { $0.log } }
    func requests(for path: String) -> Int { log.count { $0 == path } }
    /// `FileServerSource` 为这个网盘路径获取下载链接的次数。
    func resolves(for path: String) -> Int { resolveLog.withLock { $0.count { $0 == path } } }
    func recordResolve(_ path: String) { resolveLog.withLock { $0.append(path) } }
    /// 停住所有响应，直到设为 false 或请求被取消。
    func setStalled(_ stalled: Bool) { state.withLock { $0.stalled = stalled } }
    /// 只停住以这些后缀结尾的路径。
    func setStalling(_ suffixes: Set<String>) { state.withLock { $0.stalling = suffixes } }
    /// 以这些后缀结尾的路径返回 500。
    func setFailing(_ suffixes: Set<String>) { state.withLock { $0.failing = suffixes } }

    func url(for remotePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = remotePath
        return components.url!
    }

    func serve(_ request: URLRequest, on connection: FileProtocol) {
        let url = request.url!
        let path = url.path(percentEncoded: false)
        let isFailing = state.withLock { state in
            state.log.append(path)
            return state.failing.contains { path.hasSuffix($0) }
        }
        let client = connection.client!
        func respond(_ status: Int, headers: [String: String] = [:], body: Data = Data()) {
            var headers = headers
            headers["Content-Length"] = String(body.count)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client.urlProtocol(connection, didLoad: body) }
            client.urlProtocolDidFinishLoading(connection)
        }
        if isFailing { return respond(500) }
        guard let file = netdisk.data(at: path) else { return respond(404) }

        var body = file
        var status = 200
        var headers: [String: String] = [:]
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), !file.isEmpty {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let first = Int(bounds[0]) ?? 0
            let last = min(Int(bounds[1]) ?? file.count - 1, file.count - 1)
            body = file.subdata(in: first..<last + 1)
            status = 206
            headers["Content-Range"] = "bytes \(first)-\(last)/\(file.count)"
        }
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 先发一部分，停住时留下可以续传的进度。
        let half = body.count / 2
        if half > 0 { client.urlProtocol(connection, didLoad: body.prefix(half)) }
        while state.withLock({ $0.stalled || $0.stalling.contains { path.hasSuffix($0) } }) {
            if connection.isStopped { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if connection.isStopped { return }
        if body.count > half { client.urlProtocol(connection, didLoad: body.subdata(in: half..<body.count)) }
        client.urlProtocolDidFinishLoading(connection)
    }
}

final class FileProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock<[String: FileServer]>(initialState: [:])
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private static let apiHandlers = OSAllocatedUnfairLock<[String: (status: Int, body: @Sendable (URLRequest) throws -> Data)]>(initialState: [:])

    static func registerAPI(_ id: String, statusCode: Int = 200, handler: @escaping @Sendable (URLRequest) throws -> Data) {
        apiHandlers.withLock { $0[id] = (statusCode, handler) }
    }
    static func removeAPI(_ id: String) { apiHandlers.withLock { $0[id] = nil } }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: body) as! [String: Any]
    }

    static func register(_ server: FileServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileProtocol.self]
        return URLSession(configuration: configuration)
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        if let id = request.value(forHTTPHeaderField: "X-Ferry-Test-API"),
           let handler = Self.apiHandlers.withLock({ $0[id] }) {
            do {
                let data = try handler.body(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: handler.status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
            return
        }
        guard let host = request.url?.host(), let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        DispatchQueue.global().async { server.serve(request, on: self) }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// 在真实 QuarkClient 请求边界模拟分组转存，只记录脱敏的文件和目的目录 ID。
struct QuarkAPIStub: Sendable {
    struct State {
        var folders: [String: [(fid: String, name: String)]] = ["owned": []]
        var saves: [(fids: [String], destination: String)] = []
        var queried: [String] = []
        var failQueries = Set<String>()
        var taskResponses: [String: String] = [:]
        var beforeTaskResponse: (@Sendable () throws -> Void)?
        var loseReceipts = Set<Int>()
        var afterSave: (@Sendable () throws -> Void)?
        var shareRootParentFID = "0"
        var shareParentOverrides: [String: String] = [:]
        var accountParentOverrides: [String: String] = [:]
        var saveSourceParents: [String] = []
        var shareToken = "test-only"
        var lastDetailToken: String?
        var lastDetailQuery: String?
        var shareDirectoryOverrides: [String: [(fid: String, name: String, isDirectory: Bool)]] = [:]
        var requestedShareParents: [String] = []
        var capacityPayload = #"{"total_capacity":100,"use_capacity":40}"#
        var capacityRequests: [(method: String, host: String, query: [String: String])] = []
        var httpStatus = 200
        var downloadBusinessCode: String?
        var downloadFailureMessage: String?
        var downloadRequests = 0
        var listingResponses: [String: [Int: String]] = [:]
        var listingRequests: [(path: String, query: [String: String])] = []
    }
    let id = UUID().uuidString
    let state = OSAllocatedUnfairLock(initialState: State())

    func makeDisk() -> QuarkNetdisk {
        QuarkNetdisk(client: makeClient(), account: AccountKey(provider: .quark, accountID: "test"))
    }

    func makeClient() -> QuarkClient {
        let state = state
        FileProtocol.registerAPI(id, statusCode: state.withLock { $0.httpStatus }) { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let path = components.path
            if path.hasSuffix("/file/sort") || path.hasSuffix("/share/sharepage/detail") {
                let response = state.withLock { state -> String? in
                    state.listingRequests.append((path, query))
                    return state.listingResponses[path]?[Int(query["_page"] ?? "") ?? 0]
                }
                if let response { return Data(response.utf8) }
            }
            let data: Any
            if path.hasSuffix("/file/download") {
                let failure = state.withLock { state -> (String?, String?) in
                    state.downloadRequests += 1
                    return (state.downloadBusinessCode, state.downloadFailureMessage)
                }
                if let code = failure.0 {
                    var response: [String: Any] = ["status": 400, "code": code]
                    if let message = failure.1 { response["message"] = message }
                    return try JSONSerialization.data(withJSONObject: response)
                }
                data = [["fid": "file", "size": 12, "download_url": "https://download.test/file"]]
            }
            else if path.hasSuffix("/member") {
                let payload = state.withLock { state -> String in
                    state.capacityRequests.append((request.httpMethod ?? "", components.host ?? "", query))
                    return state.capacityPayload
                }
                data = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            }
            else if path.hasSuffix("/share/sharepage/token") { data = state.withLock { ["stoken": $0.shareToken, "title": "Test share"] } }
            else if path.hasSuffix("/share/sharepage/detail") {
                let encodedQuery = components.percentEncodedQuery
                state.withLock {
                    $0.lastDetailToken = query["stoken"]
                    $0.lastDetailQuery = encodedQuery
                }
                let fid = query["pdir_fid"]!
                let files: [(String, String, Bool)]
                let overridden = state.withLock { state -> [(fid: String, name: String, isDirectory: Bool)]? in
                    state.requestedShareParents.append(fid)
                    return state.shareDirectoryOverrides[fid]
                }
                if let overridden { files = overridden }
                else {
                    switch fid {
                    case "0": files = [("docs", "docs", true), ("cover", "cover.txt", false)]
                    case "docs": files = [("readme", "readme.txt", false), ("nested", "nested", true)]
                    case "nested": files = [("report", "readme.txt", false)]
                    default: files = []
                    }
                }
                let realParent = state.withLock { $0.shareParentOverrides[fid] ?? (fid == "0" ? $0.shareRootParentFID : fid) }
                data = ["list": files.map { item in ["fid": item.0, "file_name": item.1, "dir": item.2,
                    "size": item.2 ? 0 : 12, "share_fid_token": "test-" + item.0, "pdir_fid": realParent] as [String: Any] }]
            } else if path.hasSuffix("/file/sort") {
                let parent = query["pdir_fid"]!
                let children = state.withLock { $0.folders[parent] ?? [] }
                let realParent = state.withLock { $0.accountParentOverrides[parent] ?? parent }
                data = ["list": children.map { ["fid": $0.fid, "file_name": $0.name, "dir": true, "size": 0, "pdir_fid": realParent] as [String: Any] }]
            } else if path.hasSuffix("/file") {
                let body = try FileProtocol.body(request)
                let parent = body["pdir_fid"] as! String
                let name = body["file_name"] as! String
                data = state.withLock { state -> [String: String] in
                    let fid = "created-\(state.folders.count)"
                    state.folders[parent, default: []].append((fid, name))
                    state.folders[fid] = []
                    return ["fid": fid]
                }
            } else if path.hasSuffix("/share/sharepage/save") {
                let body = try FileProtocol.body(request)
                let fids = body["fid_list"] as! [String]
                let destination = body["to_pdir_fid"] as! String
                let sourceParent = body["pdir_fid"] as! String
                let result = state.withLock { state -> (Int, Bool, (@Sendable () throws -> Void)?) in
                    state.saves.append((fids, destination))
                    state.saveSourceParents.append(sourceParent)
                    let count = state.saves.count
                    let action = state.afterSave
                    state.afterSave = nil
                    return (count, state.loseReceipts.remove(count) != nil, action)
                }
                try result.2?()
                if result.1 { throw URLError(.networkConnectionLost) }
                data = ["task_id": "task-\(result.0)"]
            } else if path.hasSuffix("/task") {
                let task = query["task_id"]!
                let failed = state.withLock { state -> Bool in
                    state.queried.append(task)
                    return state.failQueries.remove(task) != nil
                }
                if failed { throw URLError(.timedOut) }
                let result = state.withLock { state -> (String?, (@Sendable () throws -> Void)?) in
                    let callback = state.beforeTaskResponse
                    state.beforeTaskResponse = nil
                    return (state.taskResponses[task], callback)
                }
                try result.1?()
                if let response = result.0 { return Data(response.utf8) }
                data = ["status": 2]
            } else { throw URLError(.unsupportedURL) }
            return try JSONSerialization.data(withJSONObject: ["status": 200, "code": 0, "data": data])
        }
        let configuration = QuarkClient.defaultConfiguration()
        configuration.protocolClasses = [FileProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Ferry-Test-API": id]
        return QuarkClient(configuration: configuration)
    }
}

/// 把 `context` 中的网盘路径映射到桩服务器。
struct FileServerSource: DownloadSource {
    let server: FileServer

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let context = try JSONDecoder().decode(DownloadContext.self, from: request.context)
        let path = context.reference.identifier
        server.recordResolve(path)
        return ResolvedURL(url: server.url(for: path))
    }
}

/// 一个测试的临时目录、假网盘和桩服务器。
@MainActor
final class Fixture {
    let directory: URL
    let netdisk: FakeNetdisk
    let server: FileServer
    let session = FileProtocol.makeSession()

    init(share: [String: Data] = [:], emptyDirectories: Set<String> = [], disk: [String: Data] = [:]) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FerryCoreTests-\(UUID().uuidString)")
        netdisk = FakeNetdisk(share: share, emptyDirectories: emptyDirectories, disk: disk)
        server = FileServer(netdisk: netdisk)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("downloads"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var downloads: URL { directory.appendingPathComponent("downloads") }
    /// 代替系统的废纸篓。
    var trash: URL { directory.appendingPathComponent("trash") }

    /// 把项目移到 `trash` 中。测试不使用系统的废纸篓。
    static func trashItem(into trash: URL) -> @Sendable (URL) throws -> Void {
        { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)"))
        }
    }

    /// 已转存、文件列表已保存，但还没开始下载的任务。
    func makeTransferredJob() async throws -> Job {
        let entries = netdisk.rootEntries()
        var job = Job(link: FakeNetdisk.link, password: nil, entries: entries, transferFolder: "/Ferry")
        try await netdisk.transfer(FakeNetdisk.session, entries: entries, to: job.remoteDirectory)
        job.files = try await netdisk.listFilesRecursively(job.remoteDirectory).map { file in
            JobFile(remotePath: file.path, relativePath: RemotePath.relativePath(of: file.path, in: job.remoteDirectory)!, size: file.size)
        }
        job.phase = .downloading
        job.accountKey = Self.account
        job.transferDirectory = TransferDirectory(reference: .baidu(path: job.remoteDirectory, fsID: 0), name: Job.shortID(job.id))
        job.transferProgress = TransferProgress(submitted: true, completed: true)
        return job
    }
    var store: JobStore { JobStore(fileURL: directory.appendingPathComponent("jobs.json")) }

    static let account = AccountKey(provider: .baidu, accountID: "1")
    static let otherAccount = AccountKey(provider: .baidu, accountID: "2")

    static let configuration = DownloadConfiguration(
        maxConcurrentFiles: 4,
        segmentSize: .fixed(1 << 20),
        maxRetries: 0,
        retryBaseDelay: .milliseconds(1),
        retryMaxDelay: .milliseconds(2),
        progressInterval: .milliseconds(20),
        checkpointInterval: .milliseconds(20)
    )

    func makeEngine(source: (any DownloadSource)? = nil) -> DownloadEngine {
        DownloadEngine(stateDirectory: stateDirectory, source: source ?? FileServerSource(server: server),
                       configuration: Self.configuration, session: session)
    }

    func makeCoordinator(settings: FerrySettings = FerrySettings(cleanupAfterDownload: false, maxConcurrentFiles: 4), downloadFolder: URL? = nil,
                         folderAccess: any DownloadFolderAccess = SecurityScopedFolderAccess()) -> JobCoordinator {
        // 和应用一样，获取链接前检查账号。
        let source = AccountCheckedSource(FileServerSource(server: server))
        let coordinator = JobCoordinator(engine: makeEngine(source: source), store: store, settings: settings,
                                         downloadFolder: DownloadFolder(url: downloadFolder ?? downloads),
                                         folderAccess: folderAccess, trashItem: Self.trashItem(into: trash),
                                         baseConfiguration: Self.configuration)
        source.connect(coordinator)
        coordinator.netdisks[.baidu] = netdisk
        // 每个测试的每个事件都检查增量维护的计数。
        coordinator.tallyMismatchHandler = { Issue.record(Comment(rawValue: $0)) }
        return coordinator
    }

    var stateDirectory: URL { directory.appendingPathComponent("state") }

    /// 下载引擎仍在追踪的状态文件，不把升级前备份当作活跃下载。
    func stateFiles() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: stateDirectory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path).filter { $0.hasSuffix(".json") })
    }

    func contents(_ relativePath: String) -> Data? {
        try? Data(contentsOf: downloads.appending(path: relativePath))
    }
}

func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
    return data
}

/// 记录打开和关闭的下载目录。`failing` 中的路径无法打开。
final class FakeFolderAccess: DownloadFolderAccess {
    private let state = OSAllocatedUnfairLock<(opened: [String], closed: [String], failing: Set<String>)>(initialState: ([], [], []))

    var opened: [String] { state.withLock { $0.opened } }
    var closed: [String] { state.withLock { $0.closed } }
    func setFailing(_ paths: Set<String>) { state.withLock { $0.failing = paths } }

    func open(_ folder: DownloadFolder) throws -> OpenedFolder {
        try state.withLock { state in
            guard !state.failing.contains(folder.url.path) else { throw DownloadFolderError.inaccessible(folder.url) }
            state.opened.append(folder.url.path)
            return OpenedFolder(url: folder.url, isSecurityScoped: true)
        }
    }

    func close(_ folder: OpenedFolder) {
        state.withLock { $0.closed.append(folder.url.path) }
    }
}

struct TimeoutError: Error {}

@MainActor
func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(description)")
            throw TimeoutError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

extension JobCoordinator {
    func job(_ id: Job.ID) -> Job? { jobs.first { $0.id == id } }

    func waitForPhase(_ phase: Job.Phase, of id: Job.ID) async throws {
        try await waitUntil("phase \(phase)") { job(id)?.phase == phase }
    }
}


extension RemoteEntry {
    init(fsID: Int64, name: String, path: String, isDirectory: Bool, size: Int64,
         modifiedAt: Date? = nil, relativeDirectory: String = "") {
        self.init(reference: .baidu(path: path, fsID: fsID), name: name, isDirectory: isDirectory,
                  size: size, modifiedAt: modifiedAt, relativeDirectory: relativeDirectory)
    }

    var relativePath: String {
        path.hasPrefix("/share/") ? String(path.dropFirst("/share/".count)) : path
    }
}
