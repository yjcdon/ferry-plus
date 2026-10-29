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

/// 分享选择页的递归文件行，目录按需加载，勾选目录代表包含全部子项。
struct FileTreeRow<Entry: FileTreeEntry>: View {
    let node: FileNode<Entry>
    let tree: FileTree<Entry>
    /// 上层目录已勾选，这一项随目录一起下载。
    let isIncluded: Bool
    @State private var loadAttempt = 0

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("空目录").foregroundStyle(.secondary)
                    }
                    ForEach(children) { child in
                        FileTreeRow(node: child, tree: tree, isIncluded: isIncluded || tree.isSelected(node))
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
                rowLabel
            }
            // 收起、换树或关闭窗口时由 SwiftUI 取消正在执行的分页请求。
            .task(id: node.isExpanded ? loadAttempt : nil) {
                guard node.isExpanded else { return }
                await tree.load(node)
            }
        } else {
            rowLabel
        }
    }

    private var expansion: Binding<Bool> {
        Binding {
            node.isExpanded
        } set: { expanded in
            node.isExpanded = expanded
        }
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
                Text(entry?.name ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: FileIcon.systemName(for: entry?.name ?? "", isDirectory: node.isDirectory))
                    .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isIncluded { tree.setSelected(node, !tree.isSelected(node)) }
            }
            if let entry, !entry.isDirectory {
                Text(entry.size.byteCount)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
