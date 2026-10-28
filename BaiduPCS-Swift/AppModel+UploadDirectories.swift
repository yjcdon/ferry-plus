import Foundation
import FerryCore

extension AppModel {
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
