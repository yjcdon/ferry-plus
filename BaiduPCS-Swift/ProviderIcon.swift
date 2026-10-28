import AppKit
import FerryCore
import SwiftUI

/// 用网盘官网图标标识来源，保持品牌原色，不随侧边栏选中状态变成模板图。
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 20
    var accessibilityDescription: String? = nil
    private static let baidu = load("BaiduNetdisk")
    private static let quark = load("QuarkNetdisk")

    var body: some View {
        Image(nsImage: provider == .baidu ? Self.baidu : Self.quark)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityDescription ?? "")
            .accessibilityHidden(accessibilityDescription == nil)
    }

    /// 本机构建直接打包 PNG，按文件读取并缓存，避免依赖未编译的 Asset Catalog。
    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("缺少网盘品牌图标：\(name).png")
        }
        return image
    }
}
