import Foundation
import CryptoKit

/// 百度一次预上传的可恢复信息；不保存 Cookie、bdstoken 或短期签名。
public struct BaiduUploadSession: Codable, Sendable, Equatable {
    public static let partSize = 4 * 1024 * 1024
    public let uploadID: String
    public let path: String
    public let size: Int64
    public let blockMD5s: [String]
    public let pendingParts: [Int]

    private enum CodingKeys: String, CodingKey { case uploadID, path, size, blockMD5s, pendingParts }

    init(uploadID: String, path: String, size: Int64, blockMD5s: [String], pendingParts: [Int]) throws {
        guard !uploadID.isEmpty, Self.validPath(path), size >= 0 else { throw BaiduUploadError.invalidPlan }
        let count = max(1, size / Int64(Self.partSize) + (size % Int64(Self.partSize) == 0 ? 0 : 1))
        guard Int64(blockMD5s.count) == count, blockMD5s.allSatisfy(Self.validMD5),
              Set(pendingParts).count == pendingParts.count,
              pendingParts.allSatisfy({ blockMD5s.indices.contains($0) }) else { throw BaiduUploadError.invalidPlan }
        self.uploadID = uploadID
        self.path = path
        self.size = size
        self.blockMD5s = blockMD5s.map { $0.lowercased() }
        self.pendingParts = pendingParts
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(uploadID: values.decode(String.self, forKey: .uploadID),
                      path: values.decode(String.self, forKey: .path),
                      size: values.decode(Int64.self, forKey: .size),
                      blockMD5s: values.decode([String].self, forKey: .blockMD5s),
                      pendingParts: values.decode([Int].self, forKey: .pendingParts))
    }

    static func validMD5(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && !value.contains("\0") &&
        value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

public enum BaiduUploadPreparation: Sendable {
    case upload(BaiduUploadSession)
    /// 服务端已生成文件；仍需调用方完整回读验证，不能直接标记已校验完成。
    case instant(NetdiskEntry)
}

public struct BaiduUploadPartReceipt: Codable, Sendable, Equatable {
    public let index: Int
    public let size: Int
    public let md5: String
}

public enum BaiduUploadError: Error, LocalizedError, Sendable {
    case invalidPlan
    case sourceChanged
    case invalidPartReceipt
    case unresolvedInstantUpload

    public var errorDescription: String? {
        switch self {
        case .invalidPlan: "百度上传文件清单、路径或分片信息无效。"
        case .sourceChanged: "本地分片内容与上传前的校验值不同，请按新版本重新上传。"
        case .invalidPartReceipt: "百度返回的上传分片校验值不一致。"
        case .unresolvedInstantUpload: "百度返回秒传结果，但未提供可核对的文件身份，需要查询确认。"
        }
    }
}

extension BaiduClient {
    /// 按稳定的源文件摘要预创建上传；只返回协议回执，任务持久化和完成校验由调用方负责。
    public func prepareUpload(path: String, size: Int64, blockMD5s: [String],
                              contentMD5: String, sliceMD5: String) async throws -> BaiduUploadPreparation {
        // 在任何远端写入之前校验文件清单；空文件采用空内容的一片。
        _ = try BaiduUploadSession(uploadID: "validation", path: path, size: size,
                                   blockMD5s: blockMD5s, pendingParts: [])
        guard BaiduUploadSession.validMD5(contentMD5), BaiduUploadSession.validMD5(sliceMD5) else {
            throw BaiduUploadError.invalidPlan
        }
        let json = try await uploadForm("precreate", fields: [
            ("path", path), ("size", String(size)), ("isdir", "0"),
            ("block_list", try uploadBlockList(blockMD5s)), ("autoinit", "1"), ("rtype", "0"),
            ("content-md5", contentMD5.lowercased()), ("slice-md5", sliceMD5.lowercased())
        ])
        switch json["return_type"].int {
        case 1:
            guard let id = json["uploadid"].string, let raw = json["block_list"].raw as? [Any] else {
                throw BaiduError.invalidResponse
            }
            let pending = try raw.map { value -> Int in
                guard let text = JSON(value).string, let index = Int(text) else { throw BaiduError.invalidResponse }
                return index
            }
            return .upload(try BaiduUploadSession(uploadID: id, path: path, size: size,
                                                  blockMD5s: blockMD5s, pendingParts: pending))
        case 2:
            // 不用同名同大小的目录条目猜测本任务身份；未知秒传回执留给编排层核对。
            guard json["fs_id"].int64 != nil else { throw BaiduUploadError.unresolvedInstantUpload }
            return .instant(try uploadedEntry(json, path: path, size: size))
        default:
            throw BaiduError.invalidResponse
        }
    }

    /// 上传一个已经读取的有界分片，发送前后分别核对本地摘要和服务端确认值。
    public func uploadPart(_ data: Data, index: Int, session upload: BaiduUploadSession) async throws -> BaiduUploadPartReceipt {
        guard upload.blockMD5s.indices.contains(index) else { throw BaiduUploadError.invalidPlan }
        let offset = Int64(index) * Int64(BaiduUploadSession.partSize)
        let length = min(Int64(BaiduUploadSession.partSize), upload.size - offset)
        guard length >= 0, Int64(data.count) == length else { throw BaiduUploadError.invalidPlan }
        let expected = upload.blockMD5s[index]
        let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw BaiduUploadError.sourceChanged }
        let boundary = "FerryUpload" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"part.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let url = URLEncoding.url("https://d.pcs.baidu.com/rest/2.0/pcs/superfile2", [
            ("app_id", Host.panAppID), ("method", "upload"), ("type", "tmpfile"),
            ("path", upload.path), ("uploadid", upload.uploadID), ("partseq", String(index))
        ])
        let reply = try await pcsJSON(BaiduRequest(method: "POST", url: url, endpoint: .pcsFile,
            cookies: cookies(), headers: ["User-Agent": UserAgent.netdisk,
                "Referer": Host.pan + "/", "Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body))
        guard let md5 = reply["md5"].string, md5.lowercased() == expected else {
            throw BaiduUploadError.invalidPartReceipt
        }
        return BaiduUploadPartReceipt(index: index, size: data.count, md5: expected)
    }

    /// 合并预上传分片并返回准确远端身份；调用前须保存提交意图，网络失败不能当作未提交。
    public func completeUpload(_ upload: BaiduUploadSession, receipts: [BaiduUploadPartReceipt]) async throws -> NetdiskEntry {
        guard Set(receipts.map(\.index)) == Set(upload.pendingParts),
              receipts.count == upload.pendingParts.count,
              receipts.allSatisfy({ receipt in
                  upload.blockMD5s.indices.contains(receipt.index) && receipt.md5 == upload.blockMD5s[receipt.index] &&
                  Int64(receipt.size) == min(Int64(BaiduUploadSession.partSize), upload.size - Int64(receipt.index) * Int64(BaiduUploadSession.partSize))
              }) else { throw BaiduUploadError.invalidPlan }
        let json = try await uploadForm("create", fields: [
            ("path", upload.path), ("size", String(upload.size)), ("isdir", "0"),
            ("uploadid", upload.uploadID), ("block_list", try uploadBlockList(upload.blockMD5s)), ("rtype", "0")
        ])
        return try uploadedEntry(json, path: upload.path, size: upload.size)
    }

    private func uploadForm(_ endpoint: String, fields: [(String, String)]) async throws -> JSON {
        let token = try await fetchBDStoken()
        let url = URLEncoding.url(Host.pan + "/api/" + endpoint, [
            ("app_id", Host.panAppID), ("clienttype", "0"), ("web", "1"), ("bdstoken", token)
        ])
        let result = try await panJSON(BaiduRequest.form(fields, url: url, endpoint: .pcsFile,
            cookies: cookies(), headers: ["User-Agent": UserAgent.netdisk, "Referer": Host.pan + "/"]))
        guard result["errno"].int == 0 else { throw BaiduError.invalidResponse }
        return result
    }

    private func uploadBlockList(_ hashes: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(hashes.map { $0.lowercased() }), as: UTF8.self)
    }

    private func uploadedEntry(_ json: JSON, path: String, size: Int64) throws -> NetdiskEntry {
        guard let id = json["fs_id"].int64, id > 0, json["path"].string == path,
              json["size"].int64 == size, json["isdir"].int == 0 else { throw BaiduError.invalidResponse }
        return NetdiskEntry(fsID: id, name: (path as NSString).lastPathComponent,
                           path: path, isDirectory: false, size: size)
    }
}
