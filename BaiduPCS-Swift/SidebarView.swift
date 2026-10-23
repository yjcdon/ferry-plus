import BaiduKit
import FerryCore
import SwiftUI

/// 侧边栏中的任务分类。
enum JobCategory: String, CaseIterable, Identifiable {
    case all
    /// 转存中和下载中的任务，包括已暂停的任务。
    case active
    case completed
    /// 转存失败和下载失败。
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
        case .active: "arrow.down.circle"
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
}

/// 侧边栏：任务分类和每个分类的任务数。底部是账号。
struct SidebarView: View {
    @Binding var selection: JobCategory?
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.coordinator.jobs
        List(selection: $selection) {
            ForEach(JobCategory.allCases) { category in
                Label(category.title, systemImage: category.systemImage)
                    .badge(jobs.count(where: category.contains))
                    .tag(category)
            }
        }
        .edgeBar(.bottom) {
            AccountView()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// 两家账号入口共用应用会话；下载任务仍沿用当前百度链路。
private struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingLogOut = false

    var body: some View {
        Menu {
            Section("百度网盘") {
                if let account = model.account {
                    Text(account.username.isEmpty ? "百度账号" : account.username)
                    Text(model.isLoginExpired ? "登录已失效" : "已登录")
                    Button("重新登录百度…") { model.presentLogin() }
                    Button("退出百度登录") { isConfirmingLogOut = model.requestLogOut() }
                } else {
                    Text("未登录")
                    Button("登录百度网盘…") { model.presentLogin() }
                }
            }
            Section("夸克网盘") {
                QuarkAccountControls()
            }
            Divider()
            SettingsLink { Text("设置…") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("账号与登录")
                    Text(accountStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .help("百度与夸克账号")
        .logOutConfirmation(isPresented: $isConfirmingLogOut)
    }

    private var accountStatus: String {
        let baidu = model.account == nil ? "百度未登录" : "百度已登录"
        let quark = model.quark.account == nil ? "夸克未登录" : "夸克" + model.quark.state.title
        return baidu + " · " + quark
    }
}
