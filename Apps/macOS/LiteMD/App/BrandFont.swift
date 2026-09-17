import AppKit
import CoreText
import SwiftUI

/// 品牌字体 Philosopher（SIL Open Font License 1.1），只用于 “LiteMD” 字标。
/// 字体随应用打包，从 woff2 数据直接创建，不安装到系统。
enum BrandFont {
    // CTFontDescriptor 创建后不可变，可以跨线程共享。
    nonisolated(unsafe) private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "Philosopher-Regular", withExtension: "woff2"),
              let data = try? Data(contentsOf: url) as CFData,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data) as? [CTFontDescriptor] else { return nil }
        return descriptors.first
    }()

    static func nsFont(size: CGFloat) -> NSFont {
        guard let descriptor else { return NSFont.systemFont(ofSize: size, weight: .semibold) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    static func font(size: CGFloat) -> Font {
        Font(nsFont(size: size))
    }
}
