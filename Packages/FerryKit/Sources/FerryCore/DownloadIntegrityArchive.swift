import Foundation

/// 按下载任务保存历史比对依据，供移除任务后的本机数据维护使用。
/// 清单只保留路径、大小和摘要，验证结论继续由 IntegrityStore 管理。
struct DownloadIntegrityArchive: Sendable {
    let directory: URL

    /// 原子写入后读回确认，成功返回实际保存的依据；重试覆盖同一任务的归档。
    func save(_ manifest: IntegrityManifest, jobID: UUID) throws -> IntegrityManifest {
        let data = try manifest.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(jobID.uuidString).appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
        let saved = try IntegrityManifest.decode(Data(contentsOf: url))
        guard saved.version == manifest.version, saved.entries == manifest.entries else {
            throw UploadRecordError.invalid("保存任务信息失败，请重试。")
        }
        return saved
    }
}
