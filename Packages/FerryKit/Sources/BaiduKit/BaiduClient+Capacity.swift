import Foundation

/// 当前账号的总容量与已用容量，单位为字节；空间权益下降时已用容量可能超过总容量。
public struct BaiduCapacity: Decodable, Sendable, Equatable {
    public let total: Int64
    public let used: Int64

    private enum CodingKeys: String, CodingKey { case total, used }

    /// 容量字段必须是非负整数字节数，缺失或无效字段不能解释为零。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int64.self, forKey: .total)
        used = try container.decode(Int64.self, forKey: .used)
        guard total >= 0, used >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Baidu capacity values must be nonnegative byte counts."))
        }
    }
}

extension BaiduClient {
    /// 复用网页登录 Cookie 只读查询容量；业务失败、网络失败及无效响应均显式抛出。
    public func capacity() async throws -> BaiduCapacity {
        let request = BaiduRequest(url: URL(string: "\(Host.pan)/api/quota")!, endpoint: .fileList,
            cookies: cookies(), headers: ["Referer": "https://pan.baidu.com/disk/main"])
        let (data, response) = try await send(request)
        let envelope: CapacityEnvelope
        do { envelope = try JSONDecoder().decode(CapacityEnvelope.self, from: data) }
        catch let error as BaiduError { throw error }
        catch {
            if response.statusCode >= 400 { throw BaiduError.httpStatus(response.statusCode) }
            throw BaiduError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw BaiduError.httpStatus(response.statusCode) }
        return envelope.capacity
    }
}

private struct CapacityEnvelope: Decodable {
    let capacity: BaiduCapacity
    private enum CodingKeys: String, CodingKey { case errno, show_msg, errmsg }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .errno)
        guard code == 0 else {
            let message = try container.decodeIfPresent(String.self, forKey: .show_msg)
                ?? container.decodeIfPresent(String.self, forKey: .errmsg)
            throw BaiduError(code: code, message: message, endpoint: .fileList)
        }
        capacity = try BaiduCapacity(from: decoder)
    }
}
