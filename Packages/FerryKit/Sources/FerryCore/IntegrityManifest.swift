import Foundation

/// 可分享的摘要清单只含相对路径、长度和摘要，不导出账号、凭据或本地绝对路径。
public struct IntegrityManifest: Codable, Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let maximumEntries = 10_000
    public let version: Int
    public let entries: [IntegrityManifestEntry]

    public init(entries: [IntegrityManifestEntry]) throws {
        version = 1; self.entries = entries
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else { throw UploadRecordError.unsupportedVersion(version) }
        try self.init(entries: c.decode([IntegrityManifestEntry].self, forKey: .entries))
    }

    /// 导入边界先限制输入体积，再解析；未知格式与错误路径明确报错，不执行清单中的路径。
    public static func decode(_ data: Data) throws -> IntegrityManifest {
        guard data.count <= maximumBytes else { throw UploadRecordError.invalid("校验清单不能超过 4 MiB") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw UploadRecordError.invalid("校验清单不能超过 4 MiB") }
        return data
    }

    /// 仅按已选文件的完整相对路径与大小绑定，不按行号或 basename 配对。
    /// 清单条目必须均有对应选择；未列入清单的其他选择保持未验证，不补造摘要。
    public func bindings(account: AccountKey, files: [IntegrityManifestFile]) throws -> [DownloadIntegrityBinding] {
        var selected: [String: IntegrityManifestFile] = [:]
        for file in files {
            try file.validate()
            guard file.reference.provider == account.provider,
                  selected.updateValue(file, forKey: LocalPath.key(file.relativePath)) == nil else {
                throw UploadRecordError.invalid("所选文件的账号或相对路径存在冲突")
            }
        }
        return try entries.map { entry in
            guard let file = selected[LocalPath.key(entry.relativePath)], file.size == entry.size else {
                throw UploadRecordError.invalid("校验清单没有准确匹配已选文件及大小：\(entry.relativePath)")
            }
            let expectation = try IntegrityExpectation(algorithm: entry.algorithm, digest: entry.digest,
                origin: .userProvided, size: file.size, reference: file.reference)
            return try DownloadIntegrityBinding(account: account, reference: file.reference, expectation: expectation)
        }
    }

    private func validate() throws {
        guard !entries.isEmpty, entries.count <= Self.maximumEntries else {
            throw UploadRecordError.invalid("校验清单应包含 1～10000 个文件")
        }
        var paths = Set<String>()
        for entry in entries {
            try entry.validate()
            guard paths.insert(LocalPath.key(entry.relativePath)).inserted else {
                throw UploadRecordError.invalid("校验清单包含重复或有大小写冲突的路径：\(entry.relativePath)")
            }
        }
    }
}

public struct IntegrityManifestEntry: Codable, Sendable, Hashable {
    public let relativePath: String
    public let size: Int64
    public let algorithm: IntegrityAlgorithm
    public let digest: String

    public init(relativePath: String, size: Int64, algorithm: IntegrityAlgorithm, digest: String) throws {
        self.relativePath = relativePath; self.size = size; self.algorithm = algorithm; self.digest = digest.lowercased()
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case relativePath, size, algorithm, digest }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(relativePath: c.decode(String.self, forKey: .relativePath), size: c.decode(Int64.self, forKey: .size),
                      algorithm: c.decode(IntegrityAlgorithm.self, forKey: .algorithm), digest: c.decode(String.self, forKey: .digest))
    }

    fileprivate func validate() throws {
        guard LocalPath.isSafe(relativePath), size >= 0, IntegrityExpectation.isDigest(digest, algorithm: algorithm) else {
            throw UploadRecordError.invalid("校验清单的相对路径、大小或摘要无效")
        }
    }
}

/// 来自当前用户选择的文件匹配信息；只有引用与摘要绑定，不读写该路径的磁盘内容。
public struct IntegrityManifestFile: Sendable {
    public let relativePath: String
    public let size: Int64
    public let reference: RemoteReference

    public init(relativePath: String, size: Int64, reference: RemoteReference) throws {
        self.relativePath = relativePath; self.size = size; self.reference = reference
        try validate()
    }

    fileprivate func validate() throws {
        guard LocalPath.isSafe(relativePath), size >= 0, !reference.identifier.isEmpty else {
            throw UploadRecordError.invalid("校验匹配目标的路径、大小或远端引用无效")
        }
    }
}
