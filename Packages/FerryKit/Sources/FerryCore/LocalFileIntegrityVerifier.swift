import CryptoKit
import Darwin
import Foundation

/// 已完成下载的只读摘要结果。调用方负责把结果和仍有效的任务基准绑定。
public struct LocalFileIntegrityDigests: Sendable {
    public let sha256: String
    public let md5: String
}

/// 本地复验只读固定缓冲，不重下载，不移动或改写已完成文件。
public enum LocalFileIntegrityVerifier {
    /// 同时计算两种摘要，以便新 SHA-256 仍受任务原有有效 MD5 约束。
    /// 应在后台任务调用；取消、读取失败及读取期间身份变化均抛错，不当作摘要不匹配。
    public static func digests(at url: URL, expectedSize: Int64) throws -> LocalFileIntegrityDigests {
        try Task.checkCancellation()
        guard url.isFileURL, expectedSize >= 0 else { throw LocalFileIntegrityError.invalidFile }
        let original = try identity(at: url)
        guard original.size == expectedSize else { throw LocalFileIntegrityError.changed }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard try identity(descriptor: descriptor) == original else { throw LocalFileIntegrityError.changed }
        var sha = SHA256(), md5 = Insecure.MD5()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let length = try autoreleasepool {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                guard Int64(data.count) <= expectedSize - count else { throw LocalFileIntegrityError.changed }
                sha.update(data: data); md5.update(data: data)
                return Int64(data.count)
            }
            if length == 0 { break }
            count += length
        }
        try Task.checkCancellation()
        guard count == expectedSize, try identity(descriptor: descriptor) == original,
              try identity(at: url) == original else { throw LocalFileIntegrityError.changed }
        return .init(sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
                     md5: md5.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ value: stat) throws {
            guard value.st_mode & S_IFMT == S_IFREG else { throw LocalFileIntegrityError.invalidFile }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private static func identity(at url: URL) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Identity(value)
    }

    private static func identity(descriptor: Int32) throws -> Identity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Identity(value)
    }
}

public enum LocalFileIntegrityError: Error, LocalizedError, Sendable {
    case invalidFile, changed, unavailable, alreadyRunning, basisConflict, mismatch
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "请选择已完成下载的普通本地文件，不能校验目录或符号链接。"
        case .changed: "本地文件大小或读取期间的内容发生变化，请核对后重新校验。"
        case .unavailable: "仅支持全部文件均已下载的任务；任务已变化或正在移除。"
        case .alreadyRunning: "此任务正在校验本地文件，请先等待或取消。"
        case .basisConflict: "指定摘要与已有可信校验依据冲突，不能覆盖原始依据。"
        case .mismatch: "本地文件内容与校验依据不一致。"
        }
    }
}
