import BaiduKit
import FerryCore
import SwiftUI

/// 侧边栏中的任务分类。
enum JobCategory: String, CaseIterable, Identifiable {
    case all
    /// 仍有后续阶段的传输任务，包括暂停、合并和校验。
    case active
    case completed
    /// 下载或上传失败的任务。
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.up.arrow.down.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// 这个分类没有任务时的说明。
    var emptyTitle: String {
        switch self {
        case .all: "没有任务"
        case .active: "没有进行中的任务"
        case .completed: "没有已完成的任务"
        case .failed: "没有失败的任务"
        }
    }

    func contains(_ job: Job) -> Bool {
        switch (self, job.phase) {
        case (.all, _), (.active, .transferring), (.active, .downloading), (.completed, .completed), (.failed, .failed):
            true
        default:
            false
        }
    }

    /// 上传按编排阶段筛选；全跳过批次独立于已验证成功，但可在完成分类中查阅。
    func contains(_ job: UploadJob) -> Bool {
        switch self {
        case .all: true
        case .active: !job.phase.isTerminal
        case .completed: job.phase == .completed || job.phase == .skipped
        case .failed: job.phase == .failed
        }
    }
}

/// 侧边栏：任务分类和每个分类的任务数。底部是账号。
struct SidebarView: View {
    @Binding var selection: JobCategory?
    @Binding var providerFilter: Provider?
    let jobs: [Job]
    var uploadJobs: [UploadJob] = []
    var body: some View {
        List(selection: $selection) {
            ForEach(JobCategory.allCases) { category in
                Label(category.title, systemImage: category.systemImage)
                    .badge(jobs.count(where: category.contains) + uploadJobs.count(where: category.contains))
                    .tag(category)
            }
        }
        .edgeBar(.top) {
            Picker("网盘", selection: $providerFilter) {
                Text("全部网盘").tag(Optional<Provider>.none)
                ForEach(Provider.allCases) { provider in
                    Text(provider.title).tag(Optional(provider))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .edgeBar(.bottom) {
            AccountView(provider: providerFilter)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// 账号入口随列表来源展示，切换来源不会切换登录会话。
private struct AccountView: View {
    let provider: Provider?
    @Environment(AppModel.self) private var model
    @State private var isConfirmingLogOut = false

    var body: some View {
        Menu {
            if provider == nil || provider == .baidu {
                Text("百度网盘 · \(model.account.map { $0.username.isEmpty ? "百度账号" : $0.username } ?? "未登录")")
                if model.account != nil {
                    if model.isLoginExpired {
                        Text("登录已失效")
                        Button("重新登录…") { model.presentLogin() }
                    }
                    Button("退出登录") { isConfirmingLogOut = model.requestLogOut() }
                } else {
                    Button("登录…") { model.presentLogin() }
                }
            }
            if provider == nil { Divider() }
            if provider == nil || provider == .quark {
                Text("夸克网盘 · \(model.quark.summary?.name ?? "未登录")")
                QuarkAccountControls()
            }
            Divider()
            SettingsLink { Text("设置…") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: provider == .baidu ? "b.circle" : provider == .quark ? "q.circle" : "person.crop.circle").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle).lineLimit(1)
                    Text(accountStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .help(provider?.title ?? "百度与夸克账号")
        .logOutConfirmation(isPresented: $isConfirmingLogOut)
    }

    private var accountStatus: String {
        let baidu = model.account == nil ? "未登录" : model.isLoginExpired ? "登录已失效" : "已登录"
        let quark = model.quark.state.title
        if provider == .baidu { return "百度网盘 · " + baidu }
        if provider == .quark { return "夸克网盘 · " + quark }
        return "百度" + baidu + " · 夸克" + quark
    }

    private var accountTitle: String {
        switch provider {
        case .baidu:
            model.account.map { $0.username.isEmpty ? "百度账号" : $0.username } ?? "登录百度网盘…"
        case .quark:
            model.quark.summary?.name ?? "登录夸克网盘…"
        case nil:
            "账号与设置"
        }
    }
}
