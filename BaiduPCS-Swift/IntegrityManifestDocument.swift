import Foundation
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 可分享的摘要 JSON 只由 Core 清单编码产生；不导出授权、账号或本地绝对路径。
nonisolated struct IntegrityManifestDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(manifest: IntegrityManifest) throws { data = try manifest.encoded() }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw UploadRecordError.invalid("校验清单必须是 JSON 文件") }
        let manifest = try IntegrityManifest.decode(bytes)
        data = try manifest.encoded()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    /// 文件导入先有界读取再解析；读取在后台执行，可取消，清单中的路径不用于任何磁盘访问。
    static func read(at url: URL) async throws -> IntegrityManifest {
        let worker = Task.detached(priority: .utility) {
            guard url.isFileURL else { throw UploadRecordError.invalid("请选择本地 JSON 清单") }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= IntegrityManifest.maximumBytes {
                try Task.checkCancellation()
                let remaining = IntegrityManifest.maximumBytes + 1 - data.count
                let part = try handle.read(upToCount: min(1_048_576, remaining)) ?? Data()
                if part.isEmpty { break }
                data.append(part)
                if data.count > IntegrityManifest.maximumBytes { throw UploadRecordError.invalid("校验清单不能超过 4 MiB") }
            }
            try Task.checkCancellation()
            return try IntegrityManifest.decode(data)
        }
        return try await withTaskCancellationHandler {
            let manifest = try await worker.value
            try Task.checkCancellation()
            return manifest
        } onCancel: { worker.cancel() }
    }
}
