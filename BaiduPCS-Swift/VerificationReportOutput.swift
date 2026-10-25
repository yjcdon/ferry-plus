import Foundation

/// 验证命令共用编码和逐行输出；退出判据、错误处理与关闭顺序由各命令保留。
enum VerificationReportOutput {
    /// 保留各报告原有日期格式；每次独立编码，不共享可变编码器。
    static func encode<Value: Encodable>(_ report: Value, datesAsISO8601: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if datesAsISO8601 { encoder.dateEncodingStrategy = .iso8601 }
        return try encoder.encode(report)
    }

    /// 已编码报告原样输出，只补原命令约定的换行。
    static func write(_ data: Data) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
