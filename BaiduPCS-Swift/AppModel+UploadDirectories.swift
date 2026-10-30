import Foundation
import FerryCore

extension AppModel {
    /// 创建回执已含准确目录身份；直接交给文件页，避免重复列目录等待。
    func createUploadDirectory(name: String, parent: RemoteReference, account: AccountKey) async throws -> RemoteEntry {
        let disk = try netdisk(for: account.provider)
        guard disk.account == account else { throw UploadDestinationError.otherAccount }
        let session = ObjectIdentifier(disk)
        let environment = try uploadEnvironment(for: account)
        let reference = try await environment.makeDirectory(parent: parent, name: name)
        try Task.checkCancellation()
        guard accountKey(for: account.provider) == account,
              coordinator.netdisks[account.provider].map(ObjectIdentifier.init) == session else {
            throw UploadDestinationError.otherAccount
        }
        return RemoteEntry(reference: reference, name: name, isDirectory: true, size: 0)
    }
}
