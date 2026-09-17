import Foundation
import UniformTypeIdentifiers
import WebKit

/// 打包在应用内的预览库：KaTeX（公式）、highlight.js（代码高亮）、Mermaid（图表）。
/// 全部离线使用，不访问网络。许可证文本位于各自目录的 LICENSE.txt。
enum PreviewLibraries {
    static let directory: URL? = Bundle.main.url(forResource: "PreviewLibraries", withExtension: nil)

    private static func read(_ path: String) -> String {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(path)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static let katexScript = read("katex/katex.min.js")
    static let highlightScript = read("highlight/highlight.min.js")
    /// 约 3.5 MB，只在文档包含 Mermaid 图表时加载。
    static let mermaidScript = read("mermaid/mermaid.min.js")

    /// KaTeX 样式：字体改为从应用内资源协议加载。
    static let katexStylesheet = read("katex/katex.min.css")
        .replacingOccurrences(of: "url(fonts/", with: "url(\(ResourceSchemeHandler.scheme)://\(ResourceSchemeHandler.host)/katex/fonts/")
}

/// 两个只读目录：
/// - `litemd-resource://preview/<路径>`：应用内打包的 PreviewLibraries；
/// - `litemd-resource://fonts/<文件名>`：用户导入的字体（预览要靠 `@font-face` 才能用上）。
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "litemd-resource"
    nonisolated static let host = "preview"
    nonisolated static let fontsHost = "fonts"

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let directory = Self.directory(forHost: url.host()) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let file = directory.appendingPathComponent(url.path(percentEncoded: false)).standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/"), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private nonisolated static func directory(forHost host: String?) -> URL? {
        switch host {
        case Self.host: PreviewLibraries.directory?.standardizedFileURL
        case Self.fontsHost: CustomFontStore.directory.standardizedFileURL
        default: nil
        }
    }
}
