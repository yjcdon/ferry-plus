import Foundation
import FerryCore

extension AppModel {
    private struct RecentUploadDirectory: Codable {
        let account: AccountKey
        let trail: [RemoteEntry]
    }
    private static let recentUploadDirectoriesKey = "upload.recentDirectories.v1"

    /// 账号独立的最近目标仅保存目录引用；使用前必须逐级向网盘确认仍存在。
    func recentUploadDirectory(for account: AccountKey) -> [RemoteEntry]? {
        recentUploadDirectories().first { $0.account == account }?.trail
    }

    /// 仅在上传确认成功后记忆目标，不保存凭据或未确认的浏览位置。
    func rememberUploadDirectory(_ trail: [RemoteEntry], for account: AccountKey) {
        guard trail.allSatisfy({ $0.isDirectory && $0.reference.provider == account.provider }) else { return }
        var records = recentUploadDirectories().filter { $0.account != account }
        records.append(.init(account: account, trail: trail))
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recentUploadDirectoriesKey)
        }
    }

    func forgetUploadDirectory(for account: AccountKey) {
        let records = recentUploadDirectories().filter { $0.account != account }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recentUploadDirectoriesKey)
        }
    }

    private func recentUploadDirectories() -> [RecentUploadDirectory] {
        guard let data = UserDefaults.standard.data(forKey: Self.recentUploadDirectoriesKey) else { return [] }
        return (try? JSONDecoder().decode([RecentUploadDirectory].self, from: data)) ?? []
    }

    /// 只创建一次，随后有限等待准确回执 ID 可见；同名条目不能替代新目录身份。
    func createUploadDirectory(name: String, parent: RemoteReference, account: AccountKey) async throws -> RemoteEntry {
        let disk = try netdisk(for: account.provider)
        guard disk.account == account else { throw UploadDestinationError.otherAccount }
        let session = ObjectIdentifier(disk)
        let environment = try uploadEnvironment(for: account)
        let reference = try await environment.makeDirectory(parent: parent, name: name)
        for attempt in 0..<5 {
            try Task.checkCancellation()
            guard accountKey(for: account.provider) == account,
                  coordinator.netdisks[account.provider].map({ ObjectIdentifier($0) }) == session else {
                throw UploadDestinationError.otherAccount
            }
            let entries = try await disk.listDirectory(parent)
            guard accountKey(for: account.provider) == account,
                  coordinator.netdisks[account.provider].map({ ObjectIdentifier($0) }) == session else {
                throw UploadDestinationError.otherAccount
            }
            if let entry = entries.first(where: { $0.reference == reference && $0.isDirectory }) { return entry }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(400)) }
        }
        throw UploadDestinationError.remoteResultUnconfirmed
    }
}
