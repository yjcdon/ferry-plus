import FerryCore
import Foundation
import Observation

/// 文件浏览和传输筛选分别拥有位置，侧边栏切换不会改变后台任务。
enum WorkspacePage: Hashable {
    case files(Provider)
    case transfers(JobCategory)

    var provider: Provider? {
        if case .files(let provider) = self { provider } else { nil }
    }
}

/// 菜单和云端结果只传递一次明确动作，主窗口在确认面板关闭后消费。
struct WorkspaceRequest: Identifiable {
    enum Action {
        case browse(Provider?)
        case upload([URL])
        case locate(AccountKey, RemoteReference, RemoteReference?)
    }
    let id = UUID()
    let action: Action
}

/// 主窗口持有两家的列表状态和未提交文件；持久化只保存页面导航偏好。
@Observable
final class WorkspaceState {
    let baidu = DirectoryBrowserState(provider: .baidu)
    let quark = DirectoryBrowserState(provider: .quark)
    var page: WorkspacePage? {
        didSet {
            if let provider = page?.provider {
                recentProvider = provider
                UserDefaults.standard.set(provider.rawValue, forKey: Self.recentKey)
            }
            savePage()
        }
    }
    private(set) var recentProvider: Provider
    var pendingFiles: [URL] = []
    var isUploadRequested = false
    var lastAddedTransfer: TransferTaskID?
    private static let pageKey = "workspace.page.v1"
    private static let recentKey = "workspace.recentProvider.v1"

    init() {
        let defaults = UserDefaults.standard
        recentProvider = defaults.string(forKey: Self.recentKey).flatMap(Provider.init(rawValue:)) ?? .baidu
        if let raw = defaults.string(forKey: Self.pageKey) {
            if let provider = Provider(rawValue: raw) { page = .files(provider) }
            else if raw.hasPrefix("transfers."), let category = JobCategory(rawValue: String(raw.dropFirst(10))) {
                page = .transfers(category)
            } else { page = .files(.baidu) }
        } else { page = .files(.baidu) }
    }

    var isFiles: Bool { page?.provider != nil }
    var browser: DirectoryBrowserState { browser(for: page?.provider ?? recentProvider) }

    func browser(for provider: Provider) -> DirectoryBrowserState {
        provider == .baidu ? baidu : quark
    }

    /// 草稿先保留本地选择，用户在列表中明确目标后才建立上传确认。
    func prepareUpload(_ urls: [URL]) {
        var seen = Set<URL>()
        pendingFiles = (pendingFiles + urls).filter { $0.isFileURL && seen.insert($0).inserted }
        page = .files(recentProvider)
    }

    private func savePage() {
        guard let page else { return }
        let value: String
        switch page {
        case .files(let provider): value = provider.rawValue
        case .transfers(let category): value = "transfers." + category.rawValue
        }
        UserDefaults.standard.set(value, forKey: Self.pageKey)
    }
}
