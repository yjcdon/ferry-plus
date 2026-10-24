import Foundation

/// 用户确认的原始摘要只绑定精确账号、远端对象和字节数，不按名称寻找候选。
public struct DownloadIntegrityBinding: Codable, Sendable, Hashable {
    public let account: AccountKey
    public let reference: RemoteReference
    public let expectation: IntegrityExpectation

    public init(account: AccountKey, reference: RemoteReference, expectation: IntegrityExpectation) throws {
        self.account = account; self.reference = reference; self.expectation = expectation
        try validate()
    }

    public func validate() throws {
        try expectation.validate()
        guard !account.accountID.isEmpty, account.provider == reference.provider,
              !reference.identifier.isEmpty, expectation.reference == reference else {
            throw UploadRecordError.invalid("下载校验依据必须与账号和远端文件身份完全一致")
        }
        switch reference {
        case .baidu(let path, let fsID):
            guard path.hasPrefix("/"), path != "/", fsID > 0 else { throw UploadRecordError.invalid("百度校验依据缺少准确文件身份") }
        case .quark(let fid):
            guard fid != "0" else { throw UploadRecordError.invalid("夸克校验依据不能指向根目录") }
        }
    }
}
