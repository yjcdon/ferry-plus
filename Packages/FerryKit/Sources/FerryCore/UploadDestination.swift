import Foundation
import CryptoKit
import BaiduKit
import QuarkKit

/// 应用以 Keychain 实现此契约；任务 JSON 只保存 reference，不保存授权上下文。
public protocol UploadSecretStorage: Sendable {
    func save(_ data: Data, reference: String) async throws
    func load(reference: String) async throws -> Data
    func delete(reference: String) async throws
}

/// 三阶段上传策略不调度队列、不读取 UI 筛选，也不将协议成功当作内容校验成功。
public protocol UploadDestination: Sendable {
    var account: AccountKey { get }
    /// 服务端准备回执到达时立即持久化，再进行后续哈希协商等远端副作用。
    func prepare(name: String, target: RemoteReference, source: UploadSourceFingerprint, fileID: UUID,
                 onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload
    /// 只有可确定没有建立新会话／产物的准备拒绝才允许再次预创建；网络、解析及未知结果默认保留意图。
    func preparationFailureIsDefinitive(_ error: any Error) -> Bool
    /// 仅补完准备后的哈希协商；不声称查询或验证服务端已保留分片。
    func finishPreparation(_ prepared: PreparedUpload,
                           onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload
    /// 恢复时核对已保存回执；支持列片的策略须确认原会话仍保留这些准确分片。
    func validateResumedParts(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws
    func uploadPart(_ data: Data, index: Int, expectedSHA256: String,
                    prepared: PreparedUpload) async throws -> UploadPartReceipt
    /// 调用前由编排层保存合并意图；抛错可能表示结果未知，禁止据此无条件重新提交。
    func complete(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws -> RemoteReference
    /// 只用于同会话同分片的幂等发送，不适用于准备、合并或 finish。
    func shouldRetryPart(after error: any Error) -> Bool
}

extension UploadDestination {
    /// 自定义策略未声明准确拒绝语义时，失败不能证明远端没有副作用。
    public func preparationFailureIsDefinitive(_ error: any Error) -> Bool { false }

    /// 未提供服务端列片合同的策略沿用本地回执，不宣称远端分片已重新查询。
    public func validateResumedParts(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws { }

    /// 仅结构化传输错误和 HTTP 暂态可重试；业务码、凭据、摘要、配额和签名错误保持失败。
    public func shouldRetryPart(after error: any Error) -> Bool {
        let transportCode: URLError.Code?
        if let error = error as? URLError { transportCode = error.code }
        else if case BaiduError.transport(let code) = error { transportCode = code }
        else { transportCode = nil }
        if let transportCode {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(transportCode)
        }
        let status: Int
        if case BaiduError.httpStatus(let value) = error { status = value }
        else if case QuarkError.httpStatus(let value) = error { status = value }
        else if let error = error as? QuarkStorageError { status = error.status }
        else { return false }
        return status == 429 || (500...599).contains(status)
    }
}

public enum UploadDestinationError: Error, LocalizedError, Sendable {
    case invalidPreparation
    case otherAccount
    case invalidName
    case nameConflict
    case requiresChunkSize(Int64)
    case sourceMismatch
    case invalidReceipt
    case remoteResultUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidPreparation: "上传准备记录或分块基准无效。"
        case .otherAccount: "上传策略、任务与目标必须属于同一网盘账号。"
        case .invalidName: "上传文件名必须是单个有效名称。"
        case .nameConflict: "上传目标名称已被占用，请重新选择同名处理方式。"
        case .requiresChunkSize(let size): "请按服务端要求重新计算分块指纹（每片 \(size) 字节）。"
        case .sourceMismatch: "待发送内容与上传原始基准不一致。"
        case .invalidReceipt: "上传分片回执与原会话或源内容不一致。"
        case .remoteResultUnconfirmed: "服务端上传结果尚未核对到准确文件，请保留记录并查询。"
        }
    }
}

/// 可恢复的准备回执。nativeSession 只含原生非敏感会话，secretReference 指向 Keychain。
public struct PreparedUpload: Codable, Sendable, Equatable {
    public let version: Int
    public let account: AccountKey
    public let fileID: UUID
    public let partSize: Int64
    public let pendingParts: [Int]
    public let nativeSession: Data
    public let remoteReference: RemoteReference?
    public let isInstant: Bool
    public let isReadyForTransfer: Bool
    public let secretReference: String?
    public let source: UploadSourceFingerprint
    fileprivate let baiduSession: BaiduUploadSession?
    fileprivate let quarkSession: QuarkUploadSession?
    private let pendingSet: Set<Int>

    private enum CodingKeys: String, CodingKey {
        case version, account, fileID, partSize, pendingParts, nativeSession, remoteReference
        case isInstant, isReadyForTransfer, secretReference, source
    }

    /// 只在恢复边界解码并完整验证一次；逐片发送复用不可变的原生会话与分片索引。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw UploadDestinationError.invalidPreparation }
        try self.init(account: c.decode(AccountKey.self, forKey: .account), fileID: c.decode(UUID.self, forKey: .fileID),
            partSize: c.decode(Int64.self, forKey: .partSize), pendingParts: c.decode([Int].self, forKey: .pendingParts),
            nativeSession: c.decode(Data.self, forKey: .nativeSession),
            remoteReference: c.decodeIfPresent(RemoteReference.self, forKey: .remoteReference),
            isInstant: c.decode(Bool.self, forKey: .isInstant),
            isReadyForTransfer: c.decode(Bool.self, forKey: .isReadyForTransfer),
            secretReference: c.decodeIfPresent(String.self, forKey: .secretReference),
            source: c.decode(UploadSourceFingerprint.self, forKey: .source))
    }

    public var requiresRechunking: Bool { !isInstant && source.identity.size > 0 && source.chunkSize != partSize }

    fileprivate init(account: AccountKey, fileID: UUID, partSize: Int64, pendingParts: [Int], nativeSession: Data,
                     remoteReference: RemoteReference? = nil, isInstant: Bool = false, isReadyForTransfer: Bool = true,
                     secretReference: String? = nil, source: UploadSourceFingerprint) throws {
        version = 1; self.account = account; self.fileID = fileID; self.partSize = partSize
        self.pendingParts = pendingParts; self.nativeSession = nativeSession; self.remoteReference = remoteReference
        self.isInstant = isInstant; self.isReadyForTransfer = isReadyForTransfer; self.secretReference = secretReference; self.source = source
        pendingSet = Set(pendingParts)
        baiduSession = account.provider == .baidu && !nativeSession.isEmpty
            ? try JSONDecoder().decode(BaiduUploadSession.self, from: nativeSession) : nil
        quarkSession = account.provider == .quark && !nativeSession.isEmpty
            ? try JSONDecoder().decode(QuarkUploadSession.self, from: nativeSession) : nil
        try validate()
    }

    /// 重新分块只能更换分块基准，完整 SHA-256 与文件大小必须仍等于首次准备时的源版本。
    public func bindingFingerprint(_ fingerprint: UploadSourceFingerprint) throws -> PreparedUpload {
        guard fingerprint.chunkSize == partSize, fingerprint.identity.size == source.identity.size,
              fingerprint.sha256 == source.sha256, fingerprint.md5 == source.md5,
              fingerprint.sha1 == source.sha1, fingerprint.first256KiBMD5 == source.first256KiBMD5 else {
            throw UploadDestinationError.sourceMismatch
        }
        return try PreparedUpload(account: account, fileID: fileID, partSize: partSize, pendingParts: pendingParts,
            nativeSession: nativeSession, remoteReference: remoteReference, isInstant: isInstant, isReadyForTransfer: isReadyForTransfer,
            secretReference: secretReference, source: fingerprint)
    }

    /// 恢复记录在协议入口统一校验，避免损坏或跨账号检查点触发服务端写入。
    public func validate() throws {
        try Self.validateSource(source)
        guard version == 1, !account.accountID.isEmpty, partSize > 0, partSize <= 64 * 1024 * 1024,
              Set(pendingParts).count == pendingParts.count,
              !(secretReference?.isEmpty ?? false) else { throw UploadDestinationError.invalidPreparation }
        let count = source.identity.size == 0 ? 1 : (source.identity.size - 1) / partSize + 1
        guard pendingParts.allSatisfy({ $0 >= 0 && Int64($0) < count }),
              !isInstant || (isReadyForTransfer && remoteReference != nil && pendingParts.isEmpty),
              isInstant || !nativeSession.isEmpty,
              remoteReference == nil || remoteReference?.provider == account.provider,
              remoteReference == nil || remoteReference?.identifier.isEmpty == false else {
            throw UploadDestinationError.invalidPreparation
        }
        switch account.provider {
        case .baidu:
            if isInstant {
                guard nativeSession.isEmpty, secretReference == nil,
                      case .baidu(_, let id) = remoteReference, id > 0 else { throw UploadDestinationError.invalidPreparation }
            } else {
                let hashes = source.identity.size == 0 ? [Self.emptyMD5] : source.chunks.map(\.md5)
                guard let session = baiduSession, isReadyForTransfer, secretReference == nil,
                      partSize == Int64(BaiduUploadSession.partSize), session.size == source.identity.size,
                      source.identity.size == 0 || source.chunkSize == partSize,
                      session.pendingParts == pendingParts, session.blockMD5s == hashes else {
                    throw UploadDestinationError.invalidPreparation
                }
            }
        case .quark:
            guard let session = quarkSession, secretReference != nil,
                  session.size == source.identity.size, Int64(session.partSize) == partSize,
                  isInstant || pendingParts == Array(0..<session.partCount),
                  !isInstant || remoteReference == .quark(fid: session.fileID) else {
                throw UploadDestinationError.invalidPreparation
            }
        }
    }

    fileprivate static func validateSource(_ source: UploadSourceFingerprint) throws {
        guard source.identity.size >= 0, source.chunkSize > 0,
              IntegrityExpectation.isDigest(source.sha256, algorithm: .sha256),
              IntegrityExpectation.isDigest(source.md5, algorithm: .md5),
              IntegrityExpectation.isDigest(source.first256KiBMD5, algorithm: .md5),
              source.sha1.utf8.count == 40,
              source.sha1.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UploadDestinationError.invalidPreparation
        }
        var offset: Int64 = 0
        for (index, part) in source.chunks.enumerated() {
            guard part.index == index, part.offset == offset, offset < source.identity.size,
                  part.length == min(source.chunkSize, source.identity.size - offset),
                  IntegrityExpectation.isDigest(part.md5, algorithm: .md5),
                  IntegrityExpectation.isDigest(part.sha256, algorithm: .sha256) else {
                throw UploadDestinationError.invalidPreparation
            }
            offset += part.length
        }
        guard offset == source.identity.size else { throw UploadDestinationError.invalidPreparation }
    }

    fileprivate func checkedPart(_ data: Data, index: Int, expectedSHA256: String, account: AccountKey) throws -> UploadPartReceipt {
        guard self.account == account else { throw UploadDestinationError.otherAccount }
        guard isReadyForTransfer, !isInstant, pendingSet.contains(index) else { throw UploadDestinationError.invalidReceipt }
        if requiresRechunking { throw UploadDestinationError.requiresChunkSize(partSize) }
        let offset = Int64(index) * partSize
        let length = min(partSize, source.identity.size - offset)
        let baseline = source.identity.size == 0 ? Self.emptySHA256 : source.chunks[index].sha256
        guard Int64(data.count) == length, expectedSHA256.lowercased() == baseline,
              Self.sha256(data) == baseline else { throw UploadDestinationError.sourceMismatch }
        return .init(index: index, offset: offset, length: length, sourceSHA256: baseline, serverReceipt: "pending")
    }

    fileprivate func checkReceipts(_ receipts: [UploadPartReceipt], account: AccountKey) throws {
        guard self.account == account else { throw UploadDestinationError.otherAccount }
        guard isReadyForTransfer else { throw UploadDestinationError.invalidPreparation }
        guard !requiresRechunking else { throw UploadDestinationError.requiresChunkSize(partSize) }
        guard receipts.count == pendingParts.count, Set(receipts.map(\.index)) == Set(pendingParts) else {
            throw UploadDestinationError.invalidReceipt
        }
        for receipt in receipts {
            let offset = Int64(receipt.index) * partSize
            let baseline = source.identity.size == 0 ? Self.emptySHA256 : source.chunks[receipt.index].sha256
            guard receipt.offset == offset, receipt.length == min(partSize, source.identity.size - offset),
                  receipt.sourceSHA256 == baseline, !receipt.serverReceipt.isEmpty else { throw UploadDestinationError.invalidReceipt }
        }
    }

    fileprivate static let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"
    fileprivate static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    fileprivate static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    fileprivate static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    fileprivate static func encodedReceipt<T: Encodable>(_ value: T, base: UploadPartReceipt) throws -> UploadPartReceipt {
        .init(index: base.index, offset: base.offset, length: base.length, sourceSHA256: base.sourceSHA256,
              serverReceipt: try JSONEncoder().encode(value).base64EncodedString())
    }
    fileprivate static func decodedReceipt<T: Decodable>(_ receipt: UploadPartReceipt, as type: T.Type) throws -> T {
        guard let data = Data(base64Encoded: receipt.serverReceipt) else { throw UploadDestinationError.invalidReceipt }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// 百度上传协议适配；固定账号由应用在会话创建时绑定，不从当前列表筛选推断。
public struct BaiduUploadDestination: UploadDestination {
    public let account: AccountKey
    private let client: BaiduClient

    public init(client: BaiduClient, account: AccountKey) throws {
        guard account.provider == .baidu, !account.accountID.isEmpty else { throw UploadDestinationError.otherAccount }
        self.client = client; self.account = account
    }

    /// 百度按 4 MiB 校验分片，空文件使用空 MD5 的一片协议计划。
    public func prepare(name: String, target: RemoteReference, source: UploadSourceFingerprint, fileID: UUID,
                        onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload {
        guard PreparedUpload.validName(name) else { throw UploadDestinationError.invalidName }
        guard case .baidu(let directory, _) = target else { throw UploadDestinationError.otherAccount }
        let partSize = Int64(BaiduUploadSession.partSize)
        if source.identity.size > 0 && source.chunkSize != partSize { throw UploadDestinationError.requiresChunkSize(partSize) }
        let path = directory == "/" ? "/" + name : directory + "/" + name
        let hashes = source.identity.size == 0 ? [PreparedUpload.emptyMD5] : source.chunks.map(\.md5)
        // 完整本地边界先校验，再执行预创建，避免错误摘要计划触发远端写入。
        try PreparedUpload.validateSource(source)
        let native: BaiduUploadPreparation
        do {
            native = try await client.prepareUpload(path: path, size: source.identity.size, blockMD5s: hashes,
                                                     contentMD5: source.md5, sliceMD5: source.first256KiBMD5)
        } catch BaiduError.alreadyExists { throw UploadDestinationError.nameConflict }
        let prepared: PreparedUpload
        switch native {
        case .upload(let session):
            prepared = try .init(account: account, fileID: fileID, partSize: partSize, pendingParts: session.pendingParts,
                                 nativeSession: JSONEncoder().encode(session), source: source)
        case .instant(let entry):
            prepared = try .init(account: account, fileID: fileID, partSize: partSize, pendingParts: [], nativeSession: Data(),
                remoteReference: .baidu(path: entry.path, fsID: entry.fsID), isInstant: true, source: source)
        }
        try await onPrepared(prepared)
        return prepared
    }

    /// 这些类型来自本地凭据校验或预创建的明确业务拒绝；HTTP 状态、未知 errno、无身份秒传均不是拒绝凭据。
    public func preparationFailureIsDefinitive(_ error: any Error) -> Bool {
        if case UploadDestinationError.nameConflict = error { return true }
        guard let error = error as? BaiduError else { return false }
        switch error {
        // 当前官方上传 SDK 的 /api/precreate errno=-10 明确为空间不足；正数 10 不具有此语义。
        case .server(code: -10, message: _): return true
        case .missingBDUSS, .missingSTOKEN, .loginExpired, .loginStateMissing, .securityVerification,
             .alreadyExists, .invalidFileName, .invalidNameOrAccessDenied, .accessDenied, .unauthorized:
            return true
        default: return false
        }
    }

    /// 百度预创建已完成准备；只核对恢复记录，不重复请求产生新会话。
    public func finishPreparation(_ prepared: PreparedUpload,
                                  onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload {
        try prepared.validate()
        guard prepared.account == account, prepared.isReadyForTransfer else { throw UploadDestinationError.otherAccount }
        if !prepared.isInstant { _ = try nativeSession(prepared) }
        return prepared
    }

    /// 核对同一份内存字节的 SHA-256 后调用百度上传，回执保留原生 MD5 确认值。
    public func uploadPart(_ data: Data, index: Int, expectedSHA256: String,
                           prepared: PreparedUpload) async throws -> UploadPartReceipt {
        let base = try prepared.checkedPart(data, index: index, expectedSHA256: expectedSHA256, account: account)
        let session = try nativeSession(prepared)
        let receipt = try await client.uploadPart(data, index: index, session: session)
        return try PreparedUpload.encodedReceipt(receipt, base: base)
    }

    /// 合并只接受本会话待发片的准确回执；合并超时交由编排层按持久意图核对。
    public func complete(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws -> RemoteReference {
        try prepared.checkReceipts(receipts, account: account)
        if prepared.isInstant, let reference = prepared.remoteReference { return reference }
        let session = try nativeSession(prepared)
        let native = try receipts.map { receipt -> BaiduUploadPartReceipt in
            let item = try PreparedUpload.decodedReceipt(receipt, as: BaiduUploadPartReceipt.self)
            guard item.index == receipt.index, Int64(item.size) == receipt.length,
                  item.md5 == session.blockMD5s[item.index] else { throw UploadDestinationError.invalidReceipt }
            return item
        }
        let entry = try await client.completeUpload(session, receipts: native)
        return .baidu(path: entry.path, fsID: entry.fsID)
    }

    private func nativeSession(_ prepared: PreparedUpload) throws -> BaiduUploadSession {
        guard let session = prepared.baiduSession else { throw UploadDestinationError.invalidPreparation }
        return session
    }
}

/// 夸克普通会话与敏感授权分开保存；OSS 授权由注入的 Keychain 存储提供。
public struct QuarkUploadDestination: UploadDestination {
    public let account: AccountKey
    private let client: QuarkClient
    private let secrets: any UploadSecretStorage

    public init(client: QuarkClient, account: AccountKey, secrets: any UploadSecretStorage) throws {
        guard account.provider == .quark, !account.accountID.isEmpty else { throw UploadDestinationError.otherAccount }
        self.client = client; self.account = account; self.secrets = secrets
    }

    /// 先持久化会话，再协商秒传；服务端片长变化时返回可重新绑定指纹的准备记录。
    public func prepare(name: String, target: RemoteReference, source: UploadSourceFingerprint, fileID: UUID,
                        onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload {
        guard PreparedUpload.validName(name) else { throw UploadDestinationError.invalidName }
        guard case .quark(let parentFID) = target else { throw UploadDestinationError.otherAccount }
        try PreparedUpload.validateSource(source)
        let modified = Date(timeIntervalSince1970: Double(source.identity.modifiedNanoseconds) / 1_000_000_000)
        let native = try await client.prepareUpload(name: name, parentFID: parentFID, size: source.identity.size,
                                                   createdAt: modified, modifiedAt: modified)
        let reference = "upload.authorization.\(fileID.uuidString).\(UUID().uuidString)"
        try await secrets.save(native.authorization.keychainData(), reference: reference)
        let prepared = try PreparedUpload(account: account, fileID: fileID, partSize: Int64(native.session.partSize),
            pendingParts: Array(0..<native.session.partCount), nativeSession: JSONEncoder().encode(native.session),
            isReadyForTransfer: false, secretReference: reference, source: source)
        try await onPrepared(prepared)
        return try await finishPreparation(prepared, onPrepared: onPrepared)
    }

    /// 登录与容量权益拒绝有现有结构化合同；不按任意 HTTP 4xx 或错误文字猜测预创建未发生。
    public func preparationFailureIsDefinitive(_ error: any Error) -> Bool {
        guard let error = error as? QuarkError else { return false }
        switch error {
        case .loginExpired, .missingCredential: return true
        case .serviceCode(let code), .serviceFailure(let code, _): return code == "32003"
        default: return false
        }
    }

    /// 使用已保存的原会话补完哈希协商；该请求的重复结果需由网盘明确返回，不能猜测秒传。
    public func finishPreparation(_ prepared: PreparedUpload,
                                  onPrepared: @Sendable (PreparedUpload) async throws -> Void) async throws -> PreparedUpload {
        try prepared.validate()
        guard prepared.account == account else { throw UploadDestinationError.otherAccount }
        let session = try nativeSession(prepared)
        if prepared.isReadyForTransfer { return prepared }
        let hash = try await client.negotiateUploadHash(session: session, md5: prepared.source.md5, sha1: prepared.source.sha1)
        let instant = hash == .instantCompleted
        let final = try PreparedUpload(account: account, fileID: prepared.fileID, partSize: prepared.partSize,
            pendingParts: instant ? [] : prepared.pendingParts, nativeSession: prepared.nativeSession,
            remoteReference: instant ? .quark(fid: session.fileID) : nil, isInstant: instant,
            secretReference: prepared.secretReference, source: prepared.source)
        try await onPrepared(final)
        return final
    }

    /// 只有持久回执的原会话才查询；远端缺片或 ETag 改变立即失败，不用列表认领未记录的成功片。
    public func validateResumedParts(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws {
        guard !receipts.isEmpty else { return }
        try prepared.validate()
        guard prepared.account == account else { throw UploadDestinationError.otherAccount }
        guard prepared.isReadyForTransfer, !prepared.isInstant, !prepared.requiresRechunking else {
            throw UploadDestinationError.invalidPreparation
        }
        let session = try nativeSession(prepared)
        var local: [Int: QuarkUploadPartReceipt] = [:]
        let pending = Set(prepared.pendingParts)
        for receipt in receipts {
            guard pending.contains(receipt.index), local[receipt.index] == nil else {
                throw UploadDestinationError.invalidReceipt
            }
            let native = try PreparedUpload.decodedReceipt(receipt, as: QuarkUploadPartReceipt.self)
            let baselineSHA = session.size == 0 ? PreparedUpload.emptySHA256 : prepared.source.chunks[receipt.index].sha256
            let baselineMD5 = session.size == 0 ? PreparedUpload.emptyMD5 : prepared.source.chunks[receipt.index].md5
            guard native.uploadID == session.uploadID, native.number == receipt.index + 1,
                  Int64(native.size) == receipt.length, receipt.offset == Int64(receipt.index) * prepared.partSize,
                  receipt.length == min(prepared.partSize, session.size - receipt.offset), receipt.sourceSHA256 == baselineSHA,
                  Self.partETag(native.etag) == baselineMD5 else { throw UploadDestinationError.invalidReceipt }
            local[receipt.index] = native
        }
        let remote = try await client.listUploadParts(session: session, authorization: authorization(prepared))
        let listed = Dictionary(uniqueKeysWithValues: remote.map { ($0.number - 1, $0) })
        for (index, receipt) in local {
            guard let actual = listed[index], actual.uploadID == receipt.uploadID, actual.size == receipt.size,
                  Self.partETag(actual.etag) == Self.partETag(receipt.etag) else {
                throw UploadDestinationError.invalidReceipt
            }
        }
    }

    private static func partETag(_ value: String) -> String {
        let text = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
        return text.lowercased()
    }

    /// 只发送已与源分块 SHA-256 匹配的同一份字节；原生层转换为 OSS 的一基片号。
    public func uploadPart(_ data: Data, index: Int, expectedSHA256: String,
                           prepared: PreparedUpload) async throws -> UploadPartReceipt {
        let base = try prepared.checkedPart(data, index: index, expectedSHA256: expectedSHA256, account: account)
        let session = try nativeSession(prepared)
        let authorization = try await authorization(prepared)
        let native = try await client.uploadPart(session: session, authorization: authorization, number: index + 1, data: data)
        return try PreparedUpload.encodedReceipt(native, base: base)
    }

    /// OSS 合并后 finish，再按准备回执的准确 fid 核对，不能认领同名同大小的其他文件。
    public func complete(_ prepared: PreparedUpload, receipts: [UploadPartReceipt]) async throws -> RemoteReference {
        try prepared.checkReceipts(receipts, account: account)
        let session = try nativeSession(prepared)
        if !prepared.isInstant {
            let native = try receipts.map { receipt -> QuarkUploadPartReceipt in
                let item = try PreparedUpload.decodedReceipt(receipt, as: QuarkUploadPartReceipt.self)
                guard item.uploadID == session.uploadID, item.number == receipt.index + 1,
                      Int64(item.size) == receipt.length else { throw UploadDestinationError.invalidReceipt }
                return item
            }
            try await client.completeUploadParts(session: session, authorization: authorization(prepared), receipts: native)
            try await client.finishUpload(session: session)
        }
        // finish 后目录索引可能尚未可见；只重复查询，不再次合并或认领同名对象。
        // 服务端遇到竞态同名会自动另存，准确 fid 与大小才是本次对象的依据。
        for attempt in 0..<6 {
            try Task.checkCancellation()
            let entries = try await client.listDirectory(parentFID: session.parentFID)
            if let entry = entries.first(where: { $0.fid == session.fileID }) {
                guard !entry.isDirectory, entry.size == session.size else { throw UploadDestinationError.remoteResultUnconfirmed }
                return .quark(fid: session.fileID)
            }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(200 * (1 << attempt))) }
        }
        throw UploadDestinationError.remoteResultUnconfirmed
    }

    private func nativeSession(_ prepared: PreparedUpload) throws -> QuarkUploadSession {
        guard let session = prepared.quarkSession else { throw UploadDestinationError.invalidPreparation }
        return session
    }

    private func authorization(_ prepared: PreparedUpload) async throws -> QuarkUploadAuthorizationContext {
        guard let reference = prepared.secretReference else { throw UploadDestinationError.invalidPreparation }
        return try QuarkUploadAuthorizationContext(keychainData: await secrets.load(reference: reference))
    }
}
