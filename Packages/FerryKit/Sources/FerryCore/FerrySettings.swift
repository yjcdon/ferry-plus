import DownloadKit
import Foundation

/// 用户设置。
public struct FerrySettings: Codable, Sendable, Hashable {
    /// 用户选择的下载目录的 security-scoped bookmark。nil 表示使用系统的“下载”目录。
    public var downloadDirectoryBookmark: Data?
    public var transferFolder: String
    /// 下载完成后删除网盘中的任务子目录。
    public var cleanupAfterDownload: Bool
    public var maxConcurrentFiles: Int
    public var connectionsPerFile: Int
    /// 同时执行的上传批次数；每批次内部文件按上传调度处理。
    public var maxConcurrentUploads: Int
    /// 每个上传文件的分片并发；每增加一路会增加一片内容缓冲。
    public var uploadPartsPerFile: Int
    /// 每秒上传字节数，0 表示不限速。
    public var uploadBytesPerSecond: Int64
    /// 每秒下载字节数，0 表示不限速；上传后的校验回读也使用此额度。
    public var downloadBytesPerSecond: Int64
    public var quarkTransferFolder: String = "/Ferry Plus"
    public var quarkCleanupAfterDownload: Bool = true
    public var quarkConnectionsPerFile: Int = 1
    public var proxy: ProxySettings
    /// 切换到 Ferry 时，剪贴板中有新复制的分享链接就打开“添加链接”。
    public var detectsCopiedLinks: Bool

    public init(downloadDirectoryBookmark: Data? = nil, transferFolder: String = "/Ferry", cleanupAfterDownload: Bool = true,
                maxConcurrentFiles: Int = 1, connectionsPerFile: Int = 1, proxy: ProxySettings = ProxySettings(),
                detectsCopiedLinks: Bool = true, maxConcurrentUploads: Int = 1,
                uploadBytesPerSecond: Int64 = 0, downloadBytesPerSecond: Int64 = 0, uploadPartsPerFile: Int = 1) {
        self.downloadDirectoryBookmark = downloadDirectoryBookmark
        self.transferFolder = transferFolder
        self.cleanupAfterDownload = cleanupAfterDownload
        self.maxConcurrentFiles = maxConcurrentFiles
        self.connectionsPerFile = connectionsPerFile
        self.maxConcurrentUploads = maxConcurrentUploads.clamped(to: Self.concurrentUploadsRange)
        self.uploadPartsPerFile = uploadPartsPerFile.clamped(to: Self.uploadPartsRange)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.proxy = proxy
        self.detectsCopiedLinks = detectsCopiedLinks
    }

    /// 缺少或无法解码的字段用默认值，一个字段出错不会丢掉其他设置（例如下载目录的 bookmark）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        let defaults = FerrySettings()
        downloadDirectoryBookmark = value(.downloadDirectoryBookmark)
        transferFolder = value(.transferFolder) ?? defaults.transferFolder
        cleanupAfterDownload = value(.cleanupAfterDownload) ?? defaults.cleanupAfterDownload
        maxConcurrentFiles = value(.maxConcurrentFiles) ?? defaults.maxConcurrentFiles
        connectionsPerFile = value(.connectionsPerFile) ?? defaults.connectionsPerFile
        maxConcurrentUploads = value(.maxConcurrentUploads) ?? defaults.maxConcurrentUploads
        uploadPartsPerFile = value(.uploadPartsPerFile) ?? defaults.uploadPartsPerFile
        uploadBytesPerSecond = value(.uploadBytesPerSecond) ?? defaults.uploadBytesPerSecond
        downloadBytesPerSecond = value(.downloadBytesPerSecond) ?? defaults.downloadBytesPerSecond
        quarkTransferFolder = value(.quarkTransferFolder) ?? defaults.quarkTransferFolder
        quarkCleanupAfterDownload = value(.quarkCleanupAfterDownload) ?? defaults.quarkCleanupAfterDownload
        quarkConnectionsPerFile = value(.quarkConnectionsPerFile) ?? defaults.quarkConnectionsPerFile
        proxy = value(.proxy) ?? defaults.proxy
        detectsCopiedLinks = value(.detectsCopiedLinks) ?? defaults.detectsCopiedLinks
        limitConcurrency()
    }

    public static let concurrentFilesRange = 1...10
    public static let concurrentUploadsRange = 1...4
    public static let uploadPartsRange = 1...4
    public static let connectionsRange = 1...16
    /// 同时下载文件数乘以每个文件的连接数的上限。
    public static let totalConnectionsLimit = 20

    /// 按当前的每个文件的连接数，同时下载文件数可以取的值。
    public var allowedConcurrentFiles: ClosedRange<Int> {
        Self.concurrentFilesRange.clamped(to: 1...max(1, Self.totalConnectionsLimit / max(1, max(connectionsPerFile, quarkConnectionsPerFile))))
    }

    /// 按当前的同时下载文件数，每个文件的连接数可以取的值。
    public var allowedConnections: ClosedRange<Int> {
        Self.connectionsRange.clamped(to: 1...max(1, Self.totalConnectionsLimit / max(1, maxConcurrentFiles)))
    }

    /// 下载超界时先保留文件数再减少连接数；上传批次限制为 1...4，负速率归零。
    public mutating func limitConcurrency() {
        maxConcurrentFiles = maxConcurrentFiles.clamped(to: Self.concurrentFilesRange)
        connectionsPerFile = connectionsPerFile.clamped(to: allowedConnections)
        quarkConnectionsPerFile = quarkConnectionsPerFile.clamped(to: allowedConnections)
        maxConcurrentUploads = maxConcurrentUploads.clamped(to: Self.concurrentUploadsRange)
        uploadPartsPerFile = uploadPartsPerFile.clamped(to: Self.uploadPartsRange)
        uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        downloadBytesPerSecond = max(0, downloadBytesPerSecond)
    }

    public func transferFolder(for provider: Provider) -> String { provider == .baidu ? transferFolder : quarkTransferFolder }
    public func cleanupAfterDownload(for provider: Provider) -> Bool { provider == .baidu ? cleanupAfterDownload : quarkCleanupAfterDownload }
    public func connections(for provider: Provider) -> Int {
        (provider == .baidu ? connectionsPerFile : quarkConnectionsPerFile).clamped(to: allowedConnections)
    }

    /// 只覆盖并发设置，其余沿用 `base`。
    public func downloadConfiguration(base: DownloadConfiguration = DownloadConfiguration()) -> DownloadConfiguration {
        var limited = self
        limited.limitConcurrency()
        var configuration = base
        configuration.maxConcurrentFiles = limited.maxConcurrentFiles
        configuration.segmentsPerFile = max(limited.connectionsPerFile, limited.quarkConnectionsPerFile)
        return configuration
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
