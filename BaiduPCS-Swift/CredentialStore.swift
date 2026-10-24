import BaiduKit
import Foundation
import QuarkKit
import Security

/// 登录信息。账号随凭据一起保存，启动时不用等校验就能显示用户名。
struct StoredLogin: Codable {
    var credential: Credential
    var account: Account
}

/// 把登录信息保存在 Keychain 中。
enum CredentialStore {
    private static let item = KeychainItem(account: "baidu-login", name: "登录信息")

    static func load() -> StoredLogin? {
        item.load().flatMap { try? JSONDecoder().decode(StoredLogin.self, from: $0) }
    }

    static func save(_ login: StoredLogin) throws {
        try item.save(JSONEncoder().encode(login))
    }

    static func delete() {
        item.delete()
    }
}

/// 夸克凭据与账号使用独立条目保存，验证工具与界面共用此入口。
struct StoredQuarkLogin: Codable {
    let credential: QuarkCredential
    let account: QuarkAccount
}

enum QuarkCredentialStore {
    private static let item = KeychainItem(account: "quark-login", name: "夸克登录信息")

    /// 仅“尚未保存”返回 nil，读取失败或数据损坏必须显示原因。
    static func load() throws -> StoredQuarkLogin? {
        guard let data = try item.loadChecked() else { return nil }
        return try JSONDecoder().decode(StoredQuarkLogin.self, from: data)
    }

    static func save(_ login: StoredQuarkLogin) throws {
        try item.save(JSONEncoder().encode(login))
    }

    static func delete() throws { try item.deleteChecked() }
}

/// 把 SOCKS5 代理的密码保存在 Keychain 中。代理的其他设置在 `FerrySettings` 中。
enum ProxyPasswordStore {
    private static let item = KeychainItem(account: "socks-proxy", name: "代理密码")

    /// 没有保存密码时返回空字符串。
    static func load() -> String {
        item.load().flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 密码为空时删除这一项。
    static func save(_ password: String) throws {
        if password.isEmpty {
            item.delete()
        } else {
            try item.save(Data(password.utf8))
        }
    }
}

/// Keychain 中的一项通用密码。service 是应用的 bundle id。
struct KeychainItem {
    let account: String
    /// 保存失败时提示中的名称。
    let name: String

    private static let service = Bundle.main.bundleIdentifier ?? "Ferry"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func load() -> Data? {
        try? loadChecked()
    }

    func loadChecked() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CocoaError(.coderReadCorrupt) }
        return data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

    func deleteChecked() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法把\(name)保存到钥匙串（\(status)）。"])
        }
    }
}
