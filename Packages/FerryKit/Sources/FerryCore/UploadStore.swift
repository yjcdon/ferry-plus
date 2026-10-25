import Foundation

/// 单个批次元数据与每文件检查点分别原子写入；调用方先保存意图，再发服务端请求。
/// actor 串行化本进程写入，不支持多个应用进程同时写同一状态目录。
public actor UploadStore {
    public let directory: URL

    public init(directory: URL = FerryDirectories.applicationSupport.appendingPathComponent("Uploads", isDirectory: true)) {
        self.directory = directory
    }

    /// 枚举批次摘要，不载入完整文件清单或分片；有坏记录时显式失败并保留原文件。
    public func loadJobs() throws -> [UploadJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [UploadJob] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("job.json")
            // 创建未完成的暂存目录没有 manifest，不能作为可恢复批次展示。
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let job: UploadJob = try UploadDiskRecord.read(at: url)
            try job.validate()
            guard folder.lastPathComponent == job.id.uuidString else { throw UploadRecordError.invalid("批次目录与记录 ID 不一致") }
            result.append(job)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    public func loadJob(id: UUID) throws -> UploadJob {
        let job: UploadJob = try UploadDiskRecord.read(at: jobURL(id))
        try job.validate()
        guard job.id == id else { throw UploadRecordError.invalid("批次 ID 不一致") }
        return job
    }

    /// 扫描时逐项写入；manifest 最后发布，未发布的记录不会进入任务列表。
    public func stageFile(_ file: UploadFile, account: AccountKey) throws {
        if FileManager.default.fileExists(atPath: jobURL(file.jobID).path) {
            let published = try loadJob(id: file.jobID)
            guard published.account == account else { throw UploadRecordError.invalid("上传文件账号与已发布批次不一致") }
        }
        try file.validate(account: account)
        try UploadDiskRecord.write(file, at: fileURL(jobID: file.jobID, fileID: file.id))
    }

    /// 发布批次前确认全部文件检查点已经落盘，避免 manifest 指向不存在的记录。
    public func saveJob(_ job: UploadJob) throws {
        try job.validate()
        let existing: UploadJob? = FileManager.default.fileExists(atPath: jobURL(job.id).path) ? try loadJob(id: job.id) : nil
        if let existing, existing.account != job.account {
            throw UploadRecordError.invalid("已发布批次不能更换账号")
        }
        let existingIDs = Set(existing?.fileIDs ?? [])
        for id in job.fileIDs where !existingIDs.contains(id) {
            _ = try readMemberFile(id: id, in: job)
        }
        try UploadDiskRecord.write(job, at: jobURL(job.id))
    }

    /// 每次仅加载一个文件；账号和文件归属在存储边界校验。
    public func loadFile(id: UUID, in job: UploadJob) throws -> UploadFile {
        let published = try publishedJob(for: job)
        return try readFile(id: id, in: published)
    }

    /// 按权威 manifest 流式归并文件，只读取一次成员清单；逐项校验身份和账号，不缓存完整文件数组。
    /// 调用方摘要可过时，实际参与归并的成员以此 actor 本次读取的已发布清单为准。
    public func reduceFiles<Result: Sendable>(in job: UploadJob, initial: Result,
                                             _ update: @Sendable (Result, UploadFile) throws -> Result) throws -> Result {
        let published = try publishedJob(for: job)
        var result = initial
        for id in published.fileIDs {
            result = try update(result, readMemberFile(id: id, in: published))
        }
        return result
    }

    /// 保存已发布批次的文件状态；不隐式变更聚合，聚合由调度器按检查点重建。
    public func saveFile(_ file: UploadFile, in job: UploadJob) throws {
        let published = try publishedJob(for: job)
        guard file.jobID == published.id, published.fileIDs.contains(file.id) else {
            throw UploadRecordError.invalid("文件不属于当前批次")
        }
        try file.validate(account: published.account)
        try UploadDiskRecord.write(file, at: fileURL(jobID: published.id, fileID: file.id))
    }

    /// 仅移除本地任务记录；调用方必须先处理在途请求和未决服务端副作用。
    /// 校验记录独立存储，源文件与云端文件均不受影响。
    public func moveJobToTrash(id: UUID) throws {
        try FileManager.default.trashItem(at: jobDirectory(id), resultingItemURL: nil)
    }

    /// 调用方快照可以过时，账号归属和文件成员以已落盘 manifest 为准。
    private func publishedJob(for job: UploadJob) throws -> UploadJob {
        let published = try loadJob(id: job.id)
        guard published.account == job.account else { throw UploadRecordError.invalid("上传文件账号与已发布批次不一致") }
        return published
    }

    /// 发布 manifest 前也需读取新增文件，故与已发布批次的归属检查分开。
    private func readFile(id: UUID, in job: UploadJob) throws -> UploadFile {
        guard job.fileIDs.contains(id) else { throw UploadRecordError.invalid("文件不属于当前批次") }
        return try readMemberFile(id: id, in: job)
    }

    /// 仅供已经由 manifest 成员遍历或显式成员检查证明归属的内部路径使用。
    private func readMemberFile(id: UUID, in job: UploadJob) throws -> UploadFile {
        let file: UploadFile = try UploadDiskRecord.read(at: fileURL(jobID: job.id, fileID: id))
        guard file.id == id, file.jobID == job.id else { throw UploadRecordError.invalid("上传文件 ID 不一致") }
        try file.validate(account: job.account)
        return file
    }

    private func jobDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func jobURL(_ id: UUID) -> URL { jobDirectory(id).appendingPathComponent("job.json") }
    private func fileURL(jobID: UUID, fileID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("Files", isDirectory: true).appendingPathComponent(fileID.uuidString + ".json")
    }
}

/// 独立校验库可在任务移除后继续用于下载比较；关联必须同时满足账号、精确身份和版本。
public actor IntegrityStore {
    public struct CleanupFailure: Sendable, Hashable {
        public let fileName: String
        public let reason: String
    }

    public struct Inventory: Sendable {
        public let recordIDs: [UUID]
        public let failures: [CleanupFailure]
        public var totalCount: Int { recordIDs.count + failures.count }
    }

    public struct CleanupResult: Sendable {
        public let deletedIDs: [UUID]
        public let failures: [CleanupFailure]
    }

    public let directory: URL

    public init(directory: URL = FerryDirectories.applicationSupport.appendingPathComponent("Integrity", isDirectory: true)) {
        self.directory = directory
    }

    public func save(_ record: IntegrityRecord) throws {
        try record.validate()
        try UploadDiskRecord.write(record, at: recordURL(record.id))
    }

    public func load(id: UUID) throws -> IntegrityRecord {
        let record = try readValidatedRecord(at: recordURL(id))
        guard record.id == id else { throw UploadRecordError.invalid("校验记录 ID 不一致") }
        return record
    }

    /// 版本未知时不将历史记录自动当作当前原始基准，调用方可展示候选让用户指定。
    public func matching(account: AccountKey, reference: RemoteReference, remoteVersion: String) throws -> [IntegrityRecord] {
        guard !remoteVersion.isEmpty else { throw UploadRecordError.invalid("校验关联缺少远端版本") }
        var matches: [IntegrityRecord] = []
        for url in try recordURLs() {
            let record = try readValidatedRecord(at: url)
            if record.account == account, record.reference == reference, record.remoteVersion == remoteVersion {
                matches.append(record)
            }
        }
        return matches
    }

    /// 提供已验证的 SHA-256／MD5 校验基准；版本未知时不自动认定它仍是远端当前版本。
    /// 界面须让用户确认具体基准；不得按同名文件或另一账号的记录匹配。
    public func candidates(account: AccountKey, reference: RemoteReference, size: Int64) throws -> [IntegrityRecord] {
        guard !account.accountID.isEmpty, account.provider == reference.provider, size >= 0 else {
            throw UploadRecordError.invalid("校验候选查询的账号、文件或大小无效")
        }
        var result: [IntegrityRecord] = []
        for url in try recordURLs() {
            let record = try readValidatedRecord(at: url)
            if record.account == account, record.reference == reference, record.status == .verified,
               let expectation = record.expectation, expectation.size == size {
                result.append(record)
            }
        }
        return result.sorted { ($0.verifiedAt ?? .distantPast) > ($1.verifiedAt ?? .distantPast) }
    }

    /// 捕获当前 JSON 清单并验证版本、内容及文件名；无法识别的原始记录保留并逐项报告。
    public func inventory() throws -> Inventory {
        let urls = try recordURLs().sorted { $0.lastPathComponent < $1.lastPathComponent }
        var ids: [UUID] = []
        var failures: [CleanupFailure] = []
        for url in urls {
            do {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString + ".json" else {
                    throw UploadRecordError.invalid("校验记录文件名不是规范 ID")
                }
                _ = try load(id: id)
                ids.append(id)
            } catch {
                failures.append(CleanupFailure(fileName: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return Inventory(recordIDs: ids, failures: failures)
    }

    /// 只处理用户确认的有限 ID 快照；每项删除前重新验证，新记录不加入本轮清理。
    public func moveToTrash(ids: [UUID]) -> CleanupResult {
        var deleted: [UUID] = []
        var failures: [CleanupFailure] = []
        for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try moveToTrash(id: id)
                deleted.append(id)
            } catch {
                failures.append(CleanupFailure(fileName: id.uuidString + ".json", reason: error.localizedDescription))
            }
        }
        return CleanupResult(deletedIDs: deleted, failures: failures)
    }

    /// 明确清理校验依据时才移入废纸篓；未知版本或损坏记录保留，不随上传记录删除。
    public func moveToTrash(id: UUID) throws {
        _ = try load(id: id)
        try FileManager.default.trashItem(at: recordURL(id), resultingItemURL: nil)
    }

    /// 只共享当前目录快照，不缓存记录；查询保留枚举顺序，清理调用方自行排序。
    private func recordURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// 校验磁盘内容；文件名与 ID 的对应关系仍由需要该约束的调用方检查。
    private func readValidatedRecord(at url: URL) throws -> IntegrityRecord {
        let record: IntegrityRecord = try UploadDiskRecord.read(at: url)
        try record.validate()
        return record
    }

    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

private struct UploadDiskRecord<Value: Codable>: Codable {
    let version: Int
    let value: Value
    init(value: Value) { version = 1; self.value = value }

    private enum CodingKeys: String, CodingKey { case version, value }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw UploadRecordError.unsupportedVersion(version) }
        value = try container.decode(Value.self, forKey: .value)
    }

    static func read(at url: URL) throws -> Value {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).value
    }

    static func write(_ value: Value, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Self(value: value)).write(to: url, options: .atomic)
    }
}
