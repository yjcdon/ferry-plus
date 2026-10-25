import FerryCore
import Foundation

/// 只保留根选择和汇总，不缓存递归文件清单或读取文件内容。
nonisolated struct UploadPreflightSummary: Sendable {
    struct Root: Sendable {
        let name: String
        let isDirectory: Bool
        var bytes: Int64
    }
    let fileCount: Int
    let directoryCount: Int
    let totalBytes: Int64
    let roots: [Root]
    let issueCount: Int
    let issues: [String]
}

nonisolated struct UploadPreflightResult: Sendable {
    let summary: UploadPreflightSummary
    let availableBytes: Int64?
    let capacityReason: String?
    let conflictCount: Int
    let typeConflictCount: Int
    let mergingDirectoryCount: Int
    let requiredLowerBound: Int64
    let requiredUpperBound: Int64?
    let spaceEstimateOverflow: Bool
    var insufficientSpace: Bool { spaceEstimateOverflow || (availableBytes.map { requiredLowerBound > $0 } ?? false) }
    var canUpload: Bool { summary.issueCount == 0 && !insufficientSpace }
}

/// 预览不替代执行前检查；容量未知和跳过后实际所需空间不确定时保留未知。
nonisolated enum UploadPreflight {
    static func inspect(_ urls: [URL]) async throws -> UploadPreflightSummary {
        let authorized = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in authorized { url.stopAccessingSecurityScopedResource() } }
        let collector = Collector()
        try await UploadSource.scan(selections: urls) { event in try await collector.receive(event) }
        return await collector.summary()
    }

    static func evaluate(_ summary: UploadPreflightSummary, entries: [RemoteEntry], policy: UploadConflictPolicy,
                         availableBytes: Int64?, capacityReason: String?) -> UploadPreflightResult {
        let names = Set(summary.roots.map { key($0.name) })
        var matches: [String: RemoteEntry] = [:]
        for entry in entries where names.contains(key(entry.name)) { matches[key(entry.name)] = entry }
        var conflicts = 0, types = 0, merged = 0
        var lower: Int64 = 0, upper: Int64 = 0
        var upperKnown = true, overflow = false
        func add(_ bytes: Int64, to value: inout Int64) {
            let (sum, exceeded) = value.addingReportingOverflow(bytes)
            if exceeded || bytes < 0 { overflow = true }
            else { value = sum }
        }
        for root in summary.roots {
            guard let entry = matches[key(root.name)] else {
                add(root.bytes, to: &lower); add(root.bytes, to: &upper); continue
            }
            if root.isDirectory && entry.isDirectory {
                merged += 1; add(root.bytes, to: &upper)
                if policy != .skip { add(root.bytes, to: &lower) }
                if policy == .replace { upperKnown = false }
            } else {
                conflicts += 1
                if root.isDirectory != entry.isDirectory { types += 1 }
                if policy != .skip { add(root.bytes, to: &lower); add(root.bytes, to: &upper) }
                if policy == .replace && !root.isDirectory && !entry.isDirectory {
                    add(entry.size, to: &lower); add(entry.size, to: &upper)
                }
            }
        }
        return .init(summary: summary, availableBytes: availableBytes, capacityReason: capacityReason,
                     conflictCount: conflicts, typeConflictCount: types, mergingDirectoryCount: merged,
                     requiredLowerBound: lower, requiredUpperBound: upperKnown && !overflow ? upper : nil,
                     spaceEstimateOverflow: overflow)
    }

    private static func key(_ name: String) -> String {
        name.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping
    }

    private actor Collector {
        var files = 0, directories = 0, bytes: Int64 = 0, issueCount = 0
        var issues: [String] = []
        var roots: [String: UploadPreflightSummary.Root] = [:]
        var rootURLs: [String: URL] = [:]

        /// 逐项检查元数据及协议共有的安全名称；只保留前20个原因，另计完整问题数。
        func receive(_ event: UploadSourceScanEvent) throws {
            try Task.checkCancellation()
            switch event {
            case .issue(let issue): note("\(issue.url.path)：\(issue.reason)")
            case .entry(let entry):
                let parts = entry.relativePath.split(separator: "/").map(String.init)
                guard let root = parts.first else { throw UploadRecordError.invalid("上传源相对路径为空") }
                if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) {
                    note("名称无效：\(entry.relativePath)")
                }
                if parts.count == 1 {
                    let normalized = UploadPreflight.key(root)
                    if let other = rootURLs[normalized], other != entry.url {
                        note("多个源项目会使用相同目标名称：\(root)")
                    }
                    rootURLs[normalized] = entry.url
                    roots[root] = .init(name: root, isDirectory: entry.kind == .directory, bytes: 0)
                }
                if entry.kind == .directory { directories += 1 }
                else {
                    let (sum, overflow) = bytes.addingReportingOverflow(entry.identity.size)
                    guard !overflow else { throw UploadRecordError.invalid("所选文件总大小超出可表示范围") }
                    bytes = sum; files += 1
                    roots[root]?.bytes += entry.identity.size
                }
            }
        }
        private func note(_ message: String) {
            issueCount += 1
            if issues.count < 20 { issues.append(message) }
        }
        func summary() -> UploadPreflightSummary {
            .init(fileCount: files, directoryCount: directories, totalBytes: bytes,
                  roots: Array(roots.values), issueCount: issueCount, issues: issues)
        }
    }
}
