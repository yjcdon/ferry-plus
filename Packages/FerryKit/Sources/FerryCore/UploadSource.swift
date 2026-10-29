import Foundation
import CryptoKit
import Darwin

/// 源文件在一个校验时点的身份；纳秒修改和状态变更时间用于发现原地修改。
public struct UploadSourceIdentity: Codable, Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedNanoseconds: Int64
    public let changedNanoseconds: Int64

    fileprivate init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec)
    }
}

/// 分块摘要与准确字节范围；零字节文件没有数据分块。
public struct UploadSourceChunkFingerprint: Codable, Sendable, Hashable {
    public let index: Int
    public let offset: Int64
    public let length: Int64
    public let md5: String
    public let sha256: String
}

/// 上传原始内容基准；摘要均为小写十六进制，不包含任何凭据。
public struct UploadSourceFingerprint: Codable, Sendable, Hashable {
    public let identity: UploadSourceIdentity
    public let sha256: String
    public let md5: String
    public let sha1: String
    public let first256KiBMD5: String
    public let chunkSize: Int64
    public let chunks: [UploadSourceChunkFingerprint]
}

public enum UploadSourceError: Error, LocalizedError, Sendable {
    case nonFileURL
    case symbolicLink(String)
    case unsupportedItem(String)
    case invalidChunkSize
    case changed(String)
    case inaccessible(String, code: Int32)
    case staleBookmark
    case contentMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .nonFileURL: "上传源必须是本地文件。"
        case .symbolicLink(let path): "不上传符号链接：\(path)"
        case .unsupportedItem(let path): "请选择普通文件或文件夹：\(path)"
        case .invalidChunkSize: "上传分块大小必须大于零。"
        case .changed(let path): "源文件已发生变化，需要重新准备上传：\(path)"
        case .inaccessible(let path, let code): "源文件读取失败，请重新选择：\(path)（系统错误 \(code)）"
        case .staleBookmark: "上传文件授权已过期，请重新选择文件。"
        case .contentMismatch(let path): "源文件内容与上传基准不一致：\(path)"
        }
    }
}

public enum UploadSourceItemKind: String, Codable, Sendable { case file, directory }

/// 相对路径以被选根项目的名称开头；目录本身也入清单，因此空目录不会丢失。
public struct UploadSourceEntry: Codable, Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let kind: UploadSourceItemKind
    public let identity: UploadSourceIdentity
}

/// 扫描遇到的不可访问或不支持项目；调用方必须展示，不能作为成功清单静默跳过。
public struct UploadSourceIssue: Codable, Sendable, Hashable {
    public let url: URL
    public let reason: String
}

public enum UploadSourceScanEvent: Sendable {
    case entry(UploadSourceEntry)
    case issue(UploadSourceIssue)
}

/// 文件枚举、授权和内容基准。读取缓冲固定为 1 MiB，分块大小不扩大内容缓冲。
public enum UploadSource {
    private static let readSize = 1_048_576

    /// 保存用户选择的源授权；调用方在扫描、校验和发送整个访问期保持授权有效。
    public static func bookmark(for url: URL) throws -> Data {
        guard url.isFileURL else { throw UploadSourceError.nonFileURL }
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 恢复源授权。过期书签需重新选择，不能悄悄改为仅凭同名路径读取。
    public static func resolve(bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw UploadSourceError.staleBookmark }
        return url
    }

    /// 检查路径所指源身份，不跟随最终组件符号链接；调用方据此判断续传基准是否仍有效。
    public static func identity(of url: URL) throws -> UploadSourceIdentity {
        let value = try metadata(url)
        guard value.st_mode & S_IFMT == S_IFREG else { throw UploadSourceError.unsupportedItem(url.path) }
        return UploadSourceIdentity(value)
    }

    /// 快速上传只读取指定的256KiB真实证明；复用原始身份并核对路径与已打开描述符，不跟随替换符号链接。
    public static func readProof(of url: URL, expected: UploadSourceIdentity, range: Range<Int64>) throws -> Data {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= expected.size,
              range.upperBound - range.lowerBound == 256 * 1024 else { throw UploadSourceError.invalidChunkSize }
        guard try identity(of: url) == expected else { throw UploadSourceError.changed(url.path) }
        let handle = try openFile(url)
        defer { try? handle.close() }
        guard try descriptorIdentity(handle, url: url) == expected else { throw UploadSourceError.changed(url.path) }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        var result = Data(); result.reserveCapacity(256 * 1024)
        while result.count < 256 * 1024 {
            try Task.checkCancellation()
            let part = try autoreleasepool { try handle.read(upToCount: 256 * 1024 - result.count) ?? Data() }
            guard !part.isEmpty else { throw UploadSourceError.changed(url.path) }
            result.append(part)
        }
        guard try descriptorIdentity(handle, url: url) == expected,
              try identity(of: url) == expected else { throw UploadSourceError.changed(url.path) }
        try Task.checkCancellation()
        return result
    }

    /// 一次流式读取生成全部摘要；checkpoint 用于暂停、取消和调度让步，每 1 MiB 调用一次。
    public static func fingerprint(
        of url: URL,
        chunkSize: Int64,
        checkpoint: @Sendable () async throws -> Void = { try Task.checkCancellation() }
    ) async throws -> UploadSourceFingerprint {
        guard chunkSize > 0 else { throw UploadSourceError.invalidChunkSize }
        try Task.checkCancellation()
        let expected = try identity(of: url)
        let handle = try openFile(url)
        defer { try? handle.close() }
        guard try descriptorIdentity(handle, url: url) == expected else { throw UploadSourceError.changed(url.path) }
        var sha256 = SHA256(), md5 = Insecure.MD5(), sha1 = Insecure.SHA1()
        var prefixMD5 = Insecure.MD5(), partMD5 = Insecure.MD5(), partSHA256 = SHA256()
        var offset: Int64 = 0, partOffset: Int64 = 0, partLength: Int64 = 0
        var chunks: [UploadSourceChunkFingerprint] = []
        while true {
            try Task.checkCancellation()
            try await checkpoint()
            // Foundation 的读取与切片可能产生 autoreleased NSData；每轮释放，避免长时间 async worker
            // 在处理多 GiB 文件时积累整文件量级的临时对象。
            let length: Int64 = try autoreleasepool {
                let data = try handle.read(upToCount: readSize) ?? Data()
                if data.isEmpty { return 0 }
                let length = Int64(data.count)
                guard offset <= expected.size, length <= expected.size - offset else { throw UploadSourceError.changed(url.path) }
                sha256.update(data: data); md5.update(data: data); sha1.update(data: data)
                if offset < 262_144 {
                    prefixMD5.update(data: data.prefix(Int(min(length, 262_144 - offset))))
                }
                var start = 0
                while start < data.count {
                    let count = Int(min(Int64(data.count - start), chunkSize - partLength))
                    let slice = data[start..<(start + count)]
                    partMD5.update(data: slice); partSHA256.update(data: slice)
                    partLength += Int64(count); start += count
                    if partLength == chunkSize {
                        chunks.append(.init(index: chunks.count, offset: partOffset, length: partLength,
                                            md5: hex(partMD5.finalize()), sha256: hex(partSHA256.finalize())))
                        partOffset += partLength; partLength = 0
                        partMD5 = Insecure.MD5(); partSHA256 = SHA256()
                    }
                }
                return length
            }
            if length == 0 { break }
            offset += length
        }
        guard offset == expected.size,
              try descriptorIdentity(handle, url: url) == expected,
              try identity(of: url) == expected else { throw UploadSourceError.changed(url.path) }
        try Task.checkCancellation()
        if partLength > 0 {
            chunks.append(.init(index: chunks.count, offset: partOffset, length: partLength,
                                md5: hex(partMD5.finalize()), sha256: hex(partSHA256.finalize())))
        }
        return UploadSourceFingerprint(identity: expected, sha256: hex(sha256.finalize()), md5: hex(md5.finalize()),
                                       sha1: hex(sha1.finalize()), first256KiBMD5: hex(prefixMD5.finalize()),
                                       chunkSize: chunkSize, chunks: chunks)
    }

    /// 重新定位源后比较完整内容基准，允许路径与资源身份改变，不允许字节变化。
    public static func verifyRelocatedFile(
        at url: URL,
        against expected: UploadSourceFingerprint,
        checkpoint: @Sendable () async throws -> Void = { try Task.checkCancellation() }
    ) async throws -> UploadSourceFingerprint {
        let actual = try await fingerprint(of: url, chunkSize: expected.chunkSize, checkpoint: checkpoint)
        guard actual.identity.size == expected.identity.size, actual.sha256 == expected.sha256 else {
            throw UploadSourceError.contentMismatch(url.path)
        }
        return actual
    }

    /// 混合选择按祖先目录去重，保留隐藏项目；流式交付元数据，调用方可逐项落盘。
    /// 符号链接、特殊文件、不可读项目均产生 issue，不跟随链接、不假装扫描成功。
    public static func scan(
        selections: [URL],
        checkpoint: @Sendable () async throws -> Void = { try Task.checkCancellation() },
        onEvent: @Sendable (UploadSourceScanEvent) async throws -> Void
    ) async throws {
        guard selections.allSatisfy(\.isFileURL) else { throw UploadSourceError.nonFileURL }
        let sorted = Array(Set(selections.map(\.standardizedFileURL))).sorted {
            if $0.pathComponents.count != $1.pathComponents.count { return $0.pathComponents.count < $1.pathComponents.count }
            return $0.path < $1.path
        }
        var roots: [URL] = []
        for url in sorted {
            if roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) { continue }
            roots.append(url)
        }
        for root in roots {
            try Task.checkCancellation(); try await checkpoint()
            let rootEntry: UploadSourceEntry
            do { rootEntry = try entry(root, relativePath: root.lastPathComponent) }
            catch {
                try await onEvent(.issue(.init(url: root, reason: error.localizedDescription)))
                continue
            }
            try await onEvent(.entry(rootEntry))
            guard rootEntry.kind == .directory else { continue }
            let errors = SourceEnumerationErrors()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                    options: [], errorHandler: { url, error in
                        errors.append(.init(url: url, reason: error.localizedDescription))
                        return true
                    }) else {
                throw UploadSourceError.inaccessible(root.path, code: EACCES)
            }
            while let child = enumerator.nextObject() as? URL {
                try Task.checkCancellation(); try await checkpoint()
                for issue in errors.drain() { try await onEvent(.issue(issue)) }
                let relative = root.lastPathComponent + "/" + child.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                let item: UploadSourceEntry
                do { item = try entry(child, relativePath: relative) }
                catch {
                    enumerator.skipDescendants()
                    try await onEvent(.issue(.init(url: child, reason: error.localizedDescription)))
                    continue
                }
                try await onEvent(.entry(item))
            }
            for issue in errors.drain() { try await onEvent(.issue(issue)) }
        }
    }

    private static func entry(_ url: URL, relativePath: String) throws -> UploadSourceEntry {
        let value = try metadata(url)
        let kind: UploadSourceItemKind
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        default: throw UploadSourceError.unsupportedItem(url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw UploadSourceError.inaccessible(url.path, code: EACCES)
        }
        return .init(url: url, relativePath: relativePath, kind: kind, identity: .init(value))
    }

    private static func metadata(_ url: URL) throws -> stat {
        guard url.isFileURL else { throw UploadSourceError.nonFileURL }
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &value) == 0 } ?? false }) else {
            throw UploadSourceError.inaccessible(url.path, code: errno)
        }
        if value.st_mode & S_IFMT == S_IFLNK { throw UploadSourceError.symbolicLink(url.path) }
        return value
    }

    private static func openFile(_ url: URL) throws -> FileHandle {
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1 }
        guard fd >= 0 else { throw UploadSourceError.inaccessible(url.path, code: errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func descriptorIdentity(_ handle: FileHandle, url: URL) throws -> UploadSourceIdentity {
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0 else { throw UploadSourceError.inaccessible(url.path, code: errno) }
        guard value.st_mode & S_IFMT == S_IFREG else { throw UploadSourceError.unsupportedItem(url.path) }
        return .init(value)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// FileManager 枚举错误回调同步写入；锁使 Foundation 的 @Sendable 回调契约明确。
private final class SourceEnumerationErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UploadSourceIssue] = []
    func append(_ issue: UploadSourceIssue) { lock.lock(); defer { lock.unlock() }; values.append(issue) }
    func drain() -> [UploadSourceIssue] { lock.lock(); defer { lock.unlock() }; let result = values; values.removeAll(keepingCapacity: true); return result }
}
