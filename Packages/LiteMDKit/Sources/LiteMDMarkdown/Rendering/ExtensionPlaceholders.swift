import Foundation
import LiteMDDomain

/// 双链与公式不属于 CommonMark。解析前把它们替换为私用区占位符（保持行号不变），
/// 渲染时再换成 HTML，避免 `[[`、`_`、`\\` 等字符被 Markdown 解释。
struct ExtensionPlaceholders: Sendable {
    enum Item: Sendable {
        case wikiLink(WikiLink)
        case math(MathSpan)
    }

    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"

    private(set) var items: [(item: Item, source: String)] = []
    /// 替换后的正文。
    private(set) var text: String

    init(text: String, scan: MarkdownExtensionScanner.Result) {
        var entries: [(range: NSRange, item: Item)] = scan.wikiLinks.map { ($0.range, .wikiLink($0)) }
        entries += scan.math.map { ($0.range, .math($0)) }
        entries.sort { $0.range.location < $1.range.location }

        let source = text as NSString
        var result = ""
        var cursor = 0
        for entry in entries where entry.range.location >= cursor {
            result += source.substring(with: NSRange(location: cursor, length: entry.range.location - cursor))
            let original = source.substring(with: entry.range)
            let index = items.count
            items.append((entry.item, original))
            result += "\(Self.open)\(index)\(Self.close)"
            // 多行公式：补回换行，后续内容的行号保持不变。
            result += String(repeating: "\n", count: original.filter { $0 == "\n" }.count)
            cursor = NSMaxRange(entry.range)
        }
        result += source.substring(from: cursor)
        self.text = result
    }

    var isEmpty: Bool { items.isEmpty }

    /// 在已转义的 HTML 文本中把占位符替换为渲染结果。
    func renderHTML(in escaped: String, fileURLPrefix: String?, xhtml: Bool) -> String {
        replace(in: escaped) { index in
            let entry = items[index]
            switch entry.item {
            case .wikiLink(let link):
                return Self.html(for: link, source: entry.source, fileURLPrefix: fileURLPrefix, xhtml: xhtml)
            case .math(let math):
                let tex = HTMLEscaping.text(math.tex)
                if xhtml { return "<code class=\"math\">\(tex)</code>" }
                return math.isDisplay
                    ? "<span class=\"math math-display\">\(tex)</span>"
                    : "<span class=\"math math-inline\">\(tex)</span>"
            }
        }
    }

    /// 纯文本场景（标题、替代文字）：双链显示文字，公式保留源码。
    func plainText(_ string: String) -> String {
        replace(in: string) { index in
            switch items[index].item {
            case .wikiLink(let link): link.displayText
            case .math: items[index].source
            }
        }
    }

    /// 没有被 `renderHTML` 处理到的占位符（原始 HTML、缩进代码等）还原为转义后的源码。
    func restoreSource(in html: String) -> String {
        replace(in: html) { HTMLEscaping.text(items[$0].source) }
    }

    private func replace(in string: String, with transform: (Int) -> String) -> String {
        guard !items.isEmpty, string.contains(Self.open) else { return string }
        var result = ""
        result.reserveCapacity(string.count)
        var iterator = string.makeIterator()
        while let character = iterator.next() {
            guard character == Self.open else {
                result.append(character)
                continue
            }
            var digits = ""
            var closed = false
            while let next = iterator.next() {
                if next == Self.close {
                    closed = true
                    break
                }
                digits.append(next)
            }
            if closed, let index = Int(digits), items.indices.contains(index) {
                result += transform(index)
            } else {
                result.append(character)
                result += digits
            }
        }
        return result
    }

    static let wikiScheme = "litemd-wiki"

    private static func html(for link: WikiLink, source: String, fileURLPrefix: String?, xhtml: Bool) -> String {
        let text = HTMLEscaping.text(link.displayText)
        if xhtml { return "<span class=\"wikilink\">\(text)</span>" }

        if link.isEmbed, MarkdownFileType.isImage(URL(fileURLWithPath: link.target)),
           let src = URLSanitizer.sanitizeResource(link.target, fileURLPrefix: fileURLPrefix) {
            return "<img class=\"wikilink-embed\" src=\"\(HTMLEscaping.attribute(src))\" alt=\"\(text)\" loading=\"lazy\">"
        }
        return "<a class=\"wikilink\" href=\"\(HTMLEscaping.attribute(wikiURL(target: link.target, anchor: link.anchor)))\">\(text)</a>"
    }

    /// `litemd-wiki:Project%20Plan#Heading`
    static func wikiURL(target: String, anchor: String?) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        var url = "\(wikiScheme):" + (target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target)
        if let anchor {
            url += "#" + (anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchor)
        }
        return url
    }
}
