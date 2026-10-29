import Foundation

public enum NetdiskRenameError: Error, LocalizedError, Sendable {
    case unsupported
    case invalidName
    case nameExists
    case unconfirmed

    /// 两家按已核实的字符约束校验；英文单引号在夸克改名响应中会被转义，因此统一提示修改。
    public static func validationMessage(_ name: String, provider: Provider) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入名称" }
        if name == "." || name == ".." { return "请换一个名称" }
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"'<>|")
            .union(.controlCharacters)
        return name.unicodeScalars.contains(where: forbidden.contains) ? "包含非法字符" : nil
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported: "当前网盘不支持重命名。"
        case .invalidName: "包含非法字符"
        case .nameExists: "此位置已有同名文件或文件夹，请换一个名称。"
        case .unconfirmed: "请刷新目录，确认文件名称。"
        }
    }
}

extension Netdisk {
    /// 提交前核对账号、准确父目录和原条目，并拒绝覆盖同名对象。
    func prepareRename(entry: RemoteEntry, parent: RemoteReference, newName: String, requestingAccount: AccountKey) async throws {
        guard NetdiskRenameError.validationMessage(newName, provider: account.provider) == nil else { throw NetdiskRenameError.invalidName }
        let siblings = try await checkMutationSelection(entry: entry, parent: parent, requestingAccount: requestingAccount)
        guard !siblings.contains(where: { $0.reference != entry.reference && RemotePath.isSameComponent($0.name, newName) }) else {
            throw NetdiskRenameError.nameExists
        }
    }

    /// 只重复读取确认，不重发改名；百度按稳定 fsID、夸克按 fid 匹配改名前后对象。
    func confirmRename(entry: RemoteEntry, parent: RemoteReference, newName: String) async throws -> RemoteEntry {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .milliseconds(200 << (attempt - 1))) }
            let children = try await listDirectory(parent)
            try validateChildren(children, of: parent)
            if let result = children.first(where: { child in
                let sameIdentity: Bool
                switch (entry.reference, child.reference) {
                case (.baidu(_, let oldID), .baidu(_, let newID)): sameIdentity = oldID == newID
                case (.quark(let oldID), .quark(let newID)): sameIdentity = oldID == newID
                default: sameIdentity = false
                }
                return sameIdentity && child.name == newName && child.isDirectory == entry.isDirectory &&
                    (child.isDirectory || child.size == entry.size)
            }) { return result }
        }
        throw NetdiskRenameError.unconfirmed
    }
}
