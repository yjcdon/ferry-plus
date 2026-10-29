import SwiftUI

/// 文件选择使用清晰描边；选中和部分选中分别显示勾号、横线。
struct FileSelectionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn = configuration.isMixed || !configuration.isOn
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn || configuration.isMixed ? Color.accentColor : Color(nsColor: .textBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(configuration.isOn || configuration.isMixed ? Color.accentColor : Color.primary.opacity(0.5), lineWidth: 1.25)
                    }
                    .overlay {
                        if configuration.isOn || configuration.isMixed {
                            Image(systemName: configuration.isMixed ? "minus" : "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .frame(width: 20, height: 22)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
                .accessibilityValue(configuration.isMixed ? "部分选中" : configuration.isOn ? "已选中" : "待选择")
        }
    }
}

/// 文件列表底部仅显示已选项目数量。
struct FileSelectionSummary<Entry: FileTreeEntry>: View {
    let entries: [Entry]

    var body: some View {
        Text("已选 \(entries.count) 项")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// 文件树中的一行。目录展开时加载子项。
///
/// 调用方可以在名字后面加标签（`badge`），并决定行尾的列（`columns`，默认只有文件大小）。
struct FileTreeRow<Entry: FileTreeEntry, Badge: View, Columns: View>: View {
    let node: FileNode<Entry>
    let tree: FileTree<Entry>
    /// 上层目录已勾选，这一项随目录一起下载。
    let isIncluded: Bool
    /// 名字后面的标签，例如网盘树中的“转存目录”。
    @ViewBuilder let badge: (Entry) -> Badge
    /// 行尾的列。
    @ViewBuilder let columns: (Entry) -> Columns
    /// 仅目录支持上传入口；默认 nil 保持分享文件树的原有行为。
    var onUpload: ((Entry, [URL]) -> Void)? = nil
    /// 仅个人账号网盘提供删除；分享树不提供此操作。
    var onDelete: ((Entry) -> Void)? = nil
    var onRename: ((Entry) -> Void)? = nil
    /// 工作区按同级排序显示；未提供时保持分享页原始顺序。
    var orderedChildren: ((FileNode<Entry>) -> [FileNode<Entry>])? = nil
    var allowsExpansion = true
    var onOpen: ((Entry) -> Void)? = nil
    var onDownload: ((Entry) -> Void)? = nil
    var onCollapse: ((FileNode<Entry>) -> Void)? = nil
    var onDropTarget: ((Entry, Bool) -> Void)? = nil
    @State private var loadAttempt = 0
    @State private var isDropTarget = false

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("空目录").foregroundStyle(.secondary)
                    }
                    ForEach(orderedChildren?(node) ?? children) { child in
                        FileTreeRow(node: child, tree: tree, isIncluded: isIncluded || tree.isSelected(node),
                                    badge: badge, columns: columns, onUpload: onUpload, onDelete: onDelete, onRename: onRename,
                                    orderedChildren: orderedChildren, allowsExpansion: allowsExpansion,
                                    onOpen: onOpen, onDownload: onDownload, onCollapse: onCollapse,
                                    onDropTarget: onDropTarget)
                    }
                } else if let error = node.loadError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("重试") { loadAttempt += 1 }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("加载中").foregroundStyle(.secondary)
                    }
                }
            } label: {
                label
            }
            // 收起、换树或关闭窗口时由 SwiftUI 取消正在执行的分页请求。
            .task(id: node.isExpanded ? loadAttempt : nil) {
                guard allowsExpansion, node.isExpanded else { return }
                await tree.load(node)
            }
        } else {
            label
        }
    }

    private var expansion: Binding<Bool> {
        Binding {
            allowsExpansion && node.isExpanded
        } set: { expanded in
            guard allowsExpansion else { return }
            node.isExpanded = expanded
            if !expanded { onCollapse?(node) }
        }
    }

    @ViewBuilder private var label: some View {
        if let entry = node.entry {
            rowLabel
                .background {
                    if isDropTarget, entry.isDirectory, onUpload != nil {
                        RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.16))
                    }
                }
                .contextMenu {
                    if let onDownload {
                        Button("下载") { onDownload(entry) }
                    }
                    if entry.isDirectory, let onUpload {
                        Button("上传到此文件夹") { onUpload(entry, []) }
                    }
                    if let onRename {
                        Button("重命名") { onRename(entry) }
                    }
                    if let onDelete {
                        Button("移到回收站", role: .destructive) { onDelete(entry) }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard entry.isDirectory, let onUpload else { return false }
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    onUpload(entry, files)
                    return true
                } isTargeted: {
                    isDropTarget = $0
                    onDropTarget?(entry, $0)
                }
        } else { rowLabel }
    }

    private var rowLabel: some View {
        let entry = node.entry
        return HStack {
            Toggle("", isOn: Binding(get: { isIncluded || tree.isSelected(node) }, set: { tree.setSelected(node, $0) }))
                .labelsHidden()
                .toggleStyle(FileSelectionToggleStyle())
                .accessibilityLabel(entry?.name ?? "")
                .disabled(isIncluded)
            Label {
                HStack(spacing: 6) {
                    Text(entry?.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let entry { badge(entry) }
                }
            } icon: {
                Image(systemName: FileIcon.systemName(for: entry?.name ?? "", isDirectory: node.isDirectory))
                    .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: onOpen == nil ? 1 : 2) {
                if let onOpen, let entry, entry.isDirectory { onOpen(entry) }
                else if onOpen == nil, !isIncluded { tree.setSelected(node, !tree.isSelected(node)) }
            }
            if let entry {
                columns(entry)
            }
        }
    }
}

extension FileTreeRow where Badge == EmptyView, Columns == FileSizeText<Entry> {
    /// 没有标签，行尾只有文件大小。
    init(node: FileNode<Entry>, tree: FileTree<Entry>, isIncluded: Bool) {
        self.init(node: node, tree: tree, isIncluded: isIncluded, badge: { _ in EmptyView() },
                  columns: { FileSizeText(entry: $0) })
    }
}

/// 文件树中文件的大小。目录不显示。
struct FileSizeText<Entry: FileTreeEntry>: View {
    let entry: Entry

    var body: some View {
        if !entry.isDirectory {
            Text(entry.size.byteCount)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
