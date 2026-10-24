import Foundation
import FerryCore

/// 上传授权独立保存到现有 App 的钥匙串空间，普通任务检查点只引用标识。
/// 使用专用 account 前缀，不能覆盖百度、夸克登录或代理凭据。
@MainActor
final class KeychainUploadSecretStorage: UploadSecretStorage {
    /// 保存服务端上传恢复上下文；保留系统错误，失败时由调度停止后续写请求。
    func save(_ data: Data, reference: String) async throws {
        try item(reference).save(data)
    }

    /// 缺失授权不当成空凭据，恢复任务应明确报告并保留原有进度。
    func load(reference: String) async throws -> Data {
        guard let data = try item(reference).loadChecked() else {
            throw UploadRecordError.invalid("上传恢复授权不存在，请检查原任务的登录与恢复状态。")
        }
        return data
    }

    /// 仅清理指定上传授权，已不存在视为清理完成。
    func delete(reference: String) async throws {
        try item(reference).deleteChecked()
    }

    private func item(_ reference: String) throws -> KeychainItem {
        guard !reference.isEmpty else { throw UploadRecordError.invalid("上传恢复授权缺少标识。") }
        return KeychainItem(account: "upload-session-" + reference, name: "上传恢复授权")
    }
}
