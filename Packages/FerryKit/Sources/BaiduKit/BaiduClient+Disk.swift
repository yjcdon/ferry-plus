import Foundation

extension BaiduClient {
    // MARK: - 目录与文件

    /// 建目录。目录已存在时视为成功。
    public func createDirectory(_ path: String) async throws {
        do { _ = try await makeDirectory(path) }
        catch BaiduError.alreadyExists { return }
    }

    /// 创建任务专用目录；已存在时拒绝复用，并返回服务端文件身份供清理核对。
    public func createOwnedDirectory(_ path: String) async throws -> NetdiskEntry {
        let json = try await makeDirectory(path)
        guard let fsID = json["fs_id"].int64, fsID > 0,
              let actual = json["path"].string, actual == path else { throw BaiduError.invalidResponse }
        return NetdiskEntry(fsID: fsID, name: (path as NSString).lastPathComponent,
                            path: path, isDirectory: true, size: 0)
    }

    private func makeDirectory(_ path: String) async throws -> JSON {
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [
            ("app_id", Host.pcsAppID), ("method", "mkdir"), ("path", path),
        ])
        return try await pcsJSON(BaiduRequest(method: "POST", url: url, endpoint: .pcsFile, cookies: cookies()))
    }

    private static let listPageSize = 1000

    /// 列出目录下的一层文件和目录。
    public func listDirectory(_ path: String) async throws -> [NetdiskEntry] {
        var seen = Set<Int64>()
        return try await listPages(path, seen: &seen)
    }

    /// 递归列出目录下的全部文件（不含目录）。
    public func listFilesRecursively(_ path: String) async throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        var directories = [path]
        var seen = Set<Int64>()

        while !directories.isEmpty {
            for entry in try await listPages(directories.removeFirst(), seen: &seen) {
                if entry.isDirectory {
                    directories.append(entry.path)
                } else {
                    files.append(RemoteFile(path: entry.path, size: entry.size, fsID: entry.fsID))
                }
            }
        }
        return files
    }

    /// 完整读取一个目录；重复身份或缺失必要字段意味着结果不可信，不能返回部分列表。
    private func listPages(_ directory: String, seen: inout Set<Int64>) async throws -> [NetdiskEntry] {
        var entries: [NetdiskEntry] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let url = URLEncoding.url("\(Host.pan)/api/list", [
                ("dir", directory), ("order", "name"), ("desc", "0"), ("clienttype", "0"),
                ("num", String(Self.listPageSize)), ("page", String(page)),
            ])
            let json = try await panJSON(BaiduRequest(url: url, endpoint: .fileList, cookies: cookies()))
            guard let rawList = json["list"].raw as? [Any] else { throw BaiduError.invalidResponse }
            let list = rawList.map(JSON.init)
            for item in list {
                guard let fsID = item["fs_id"].string.flatMap(Int64.init), fsID > 0,
                      let path = item["path"].raw as? String, path.hasPrefix("/"), path != "/",
                      !Path.lastComponent(path).isEmpty,
                      let kind = item["isdir"].string.flatMap(Int.init), kind == 0 || kind == 1,
                      seen.insert(fsID).inserted else { throw BaiduError.invalidResponse }
                let isDirectory = kind == 1
                let size: Int64
                if isDirectory { size = 0 }
                else {
                    guard let bytes = item["size"].string.flatMap(Int64.init), bytes >= 0 else {
                        throw BaiduError.invalidResponse
                    }
                    size = bytes
                }
                entries.append(NetdiskEntry(
                    fsID: fsID, name: item["server_filename"].string ?? Path.lastComponent(path), path: path,
                    isDirectory: isDirectory, size: size,
                    modifiedAt: item["server_mtime"].int64.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
            }
            if list.count < Self.listPageSize { break }
            page += 1
        }
        return entries
    }

    /// 删除文件或目录，删除的内容进入回收站。路径不存在时视为成功。
    public func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        var form = MultipartForm()
        form.add(name: "param", value: try Self.pathListJSON(paths))
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [("app_id", Host.pcsAppID), ("method", "delete")])
        let request = BaiduRequest(method: "POST", url: url, endpoint: .pcsFile, cookies: cookies(),
                                   headers: ["Content-Type": form.contentType], body: form.finalized())
        do {
            _ = try await pcsJSON(request)
        } catch BaiduError.fileNotFound {
            return
        }
    }

    /// 将当前路径绑定的文件改为唯一名称，同名时明确失败；只确认本次服务回执，身份与内容由调用方另行核对。
    public func renameWithoutReplacing(path: String, newName: String) async throws {
        guard BaiduUploadSession.validPath(path), Self.validSingleName(newName) else { throw BaiduError.invalidFileName }
        try await manageWithoutReplacing(operation: "rename", path: path, destinationDirectory: nil, newName: newName)
    }

    /// 创建独立旧版本快照，同名时不覆盖；不在写入后追加列表查询，以免把查询失败误报为复制未发生。
    public func copyWithoutReplacing(path: String, destinationDirectory: String, newName: String) async throws {
        guard BaiduUploadSession.validPath(path), Self.validSingleName(newName),
              destinationDirectory == "/" || BaiduUploadSession.validPath(destinationDirectory) else { throw BaiduError.invalidFileName }
        try await manageWithoutReplacing(operation: "copy", path: path, destinationDirectory: destinationDirectory, newName: newName)
    }

    /// 单文件管理请求只发送一次；批量外层错误不能遮住该文件明确的同名冲突或缺失回执。
    private func manageWithoutReplacing(operation: String, path: String, destinationDirectory: String?, newName: String) async throws {
        let account = try await validate()
        var item = ["path": path, "newname": newName]
        if let destinationDirectory { item["dest"] = destinationDirectory; item["ondup"] = "fail" }
        let filelist = String(decoding: try JSONEncoder().encode([item]), as: UTF8.self)
        let url = URLEncoding.url(Host.pan + "/api/filemanager", [
            ("opera", operation), ("app_id", Host.panAppID), ("clienttype", "0"), ("web", "1"), ("bdstoken", account.bdstoken),
        ])
        let request = BaiduRequest.form([("async", "0"), ("ondup", "fail"), ("filelist", filelist)],
            url: url, endpoint: .pcsFile, cookies: cookies(),
            headers: ["User-Agent": UserAgent.netdisk, "Referer": Host.pan + "/"])
        let (json, response) = try await json(request)
        guard (200..<300).contains(response.statusCode) else { throw BaiduError.httpStatus(response.statusCode) }
        guard let outer = json["errno"].int else { throw BaiduError.invalidResponse }
        let message = json["show_msg"].string ?? json["errmsg"].string
        if outer != 0, outer != 12 { throw BaiduError(code: outer, message: message, endpoint: .pcsFile) }
        guard json["info"].array.count == 1, let code = json["info"][0]["errno"].int,
              let actual = json["info"][0]["path"].string,
              actual.utf8.elementsEqual(path.utf8) else { throw BaiduError.invalidResponse }
        if code != 0 { throw BaiduError(code: code, message: json["info"][0]["errmsg"].string ?? message, endpoint: .pcsFile) }
        guard outer == 0 else { throw BaiduError(code: outer, message: message, endpoint: .pcsFile) }
    }

    private static func validSingleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func pathListJSON(_ paths: [String]) throws -> String {
        struct Item: Encodable { let path: String }
        struct List: Encodable { let list: [Item] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(List(list: paths.map(Item.init))), as: UTF8.self)
    }

    // MARK: - 下载链接

    /// 取文件的下载地址。先用 `locatedownload`。它报告未授权（31044、31326、31626）或没有可用的未加密地址时，
    /// 退回 PCS `download` 地址（参考实现的帮助对 `user is not authorized` 建议这样做）。其他错误原样抛出。
    /// `preference` 是优先选用的 dlink 序号。下载后大小不符时，下次可以加 1。
    public func downloadLink(for path: String, preference: Int = 0) async throws -> DownloadLink {
        do {
            return try await locateDownload(path, preference: preference)
        } catch BaiduError.unauthorized, BaiduError.noDownloadLink {
            return pcsDownloadLink(path)
        }
    }

    func locateDownload(_ path: String, preference: Int) async throws -> DownloadLink {
        let uid = await resolveUID()
        let sign = LocateDownloadSign(bduss: credential.bduss, uid: uid, time: Int64(Date().timeIntervalSince1970))
        // 参考实现原样发送 `|`。Foundation 的 URL 不能包含 `|`，所以编码为 `%7C`，服务端解码后得到相同的值。
        let query = LocateDownloadSign.query(path: path, sign: sign).replacingOccurrences(of: "|", with: "%7C")
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", rawQuery: query)
        let json = try await pcsJSON(BaiduRequest(method: "POST", url: url, endpoint: .locateDownload, cookies: cookies()))

        let candidates = json["urls"].array
            .filter { ($0["encrypt"].int ?? 0) == 0 }
            .compactMap { $0["url"].string.flatMap(URL.init(string:)) }
        guard let url = Self.selectDownloadURL(candidates, preference: preference) else { throw BaiduError.noDownloadLink }
        return DownloadLink(url: url, headers: downloadHeaders(endpoint: .downloadLink), source: .locate)
    }

    /// 改用 https，取第 `preference` 个（超出时取最后一个）。
    /// `nb.cache` 开头的主机没有有效证书，URLSession 会拒绝，所以后面还有地址时跳过它们。
    static func selectDownloadURL(_ urls: [URL], preference: Int) -> URL? {
        guard !urls.isEmpty else { return nil }
        var index = min(max(preference, 0), urls.count - 1)
        while urls[index].host()?.hasPrefix("nb.cache") == true, index + 1 < urls.count {
            index += 1
        }
        var components = URLComponents(url: urls[index], resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? urls[index]
    }

    func pcsDownloadLink(_ path: String) -> DownloadLink {
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [
            ("app_id", Host.pcsAppID), ("method", "download"), ("path", path),
        ])
        return DownloadLink(url: url, headers: downloadHeaders(endpoint: .pcsDownload), source: .pcs)
    }

    private func downloadHeaders(endpoint: Endpoint) -> [String: String] {
        var headers = ["Cookie": cookies().headerValue]
        if let userAgent = endpoint.userAgent { headers["User-Agent"] = userAgent }
        return headers
    }
}
