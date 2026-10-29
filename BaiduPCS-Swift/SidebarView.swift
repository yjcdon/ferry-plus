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
        case .all: "添加传输任务"
        case .active: "等待任务开始"
        case .completed: "完成的任务将显示在这里"
        case .failed: "失败的任务将显示在这里"
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

/// 文件入口确定传输网盘范围，分组标题提供查看全部网盘传输的入口。
struct SidebarView: View {
    @Binding var page: WorkspacePage?
    let providerFilter: Provider?
    let onShowAll: () -> Void
    let jobs: [Job]
    var uploadJobs: [UploadJob] = []
    var body: some View {
        List(selection: $page) {
            Section("网盘") {
                ForEach(Provider.allCases) { provider in
                    Label {
                        Text(provider.title)
                    } icon: {
                        ProviderIcon(provider: provider)
                    }
                        .tag(WorkspacePage.files(provider))
                        .listRowBackground(Group {
                            if page?.provider == nil, providerFilter == provider {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                                    .padding(.horizontal, 10)
                            }
                        })
                        .foregroundStyle(providerFilter == provider ? Color.white : Color.primary)
                        .accessibilityAddTraits(providerFilter == provider ? .isSelected : [])
                }
            }
            Section {
                ForEach(JobCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .badge(jobs.count(where: category.contains) + uploadJobs.count(where: category.contains))
                        .tag(WorkspacePage.transfers(category))
                }
            } header: {
                HStack(spacing: 4) {
                    Text("传输")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if providerFilter != nil {
                        Button("查看全部", action: onShowAll)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .help("查看全部网盘的传输")
                    }
                }
                .textCase(nil)
            }
        }
        .edgeBar(.bottom) {
            AccountView()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// 账号与设置固定展示两家登录状态，不随浏览或传输筛选隐藏账号。
private struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingLogOut = false

    var body: some View {
        Menu {
            Text("百度网盘 · \(model.account.map { $0.username.isEmpty ? "百度账号" : $0.username } ?? "待登录")")
            if model.account != nil {
                if model.isLoginExpired {
                    Text("登录已失效")
                    Button("重新登录") { model.presentLogin() }
                }
                Button("退出登录") { isConfirmingLogOut = model.requestLogOut() }
            } else {
                Button("登录") { model.presentLogin() }
            }
            Divider()
            Text("夸克网盘 · \(model.quark.summary?.name ?? "待登录")")
            QuarkAccountControls()
            Divider()
            SettingsLink { Text("设置") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("账号与设置").lineLimit(1)
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
        let baidu = model.account == nil ? "待登录" : model.isLoginExpired ? "登录已失效" : "已登录"
        let quark = model.quark.state.title
        return "百度" + baidu + " · 夸克" + quark
    }
}
