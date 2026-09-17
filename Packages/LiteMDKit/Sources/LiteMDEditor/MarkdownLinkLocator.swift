import Foundation

/// 正文中某个位置上的链接或图片。
public struct LocatedLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case link
        case image
        case autolink
        case bareURL
    }

    public var kind: Kind
    /// 整个语法结构在正文中的 UTF-16 区间。
    public var range: NSRange
    public var destination: String
    public var text: String

    public init(kind: Kind, range: NSRange, destination: String, text: String) {
        self.kind = kind
        self.range = range
        self.destination = destination
        self.text = text
    }
}

/// 定位光标或右键位置所在的链接（用于右键菜单的“打开链接”等操作）。
/// 只识别单行内的行内语法：`[text](dest)`、`![alt](dest)`、`<https://…>`、裸 URL。
public enum MarkdownLinkLocator {
    public static func link(at offset: Int, in text: String) -> LocatedLink? {
        let string = text as NSString
        guard offset >= 0, offset <= string.length else { return nil }

        var lineStart = min(offset, string.length)
        while lineStart > 0, string.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        var lineEnd = min(offset, string.length)
        while lineEnd < string.length, string.character(at: lineEnd) != 0x0A { lineEnd += 1 }

        let line = string.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        let column = offset - lineStart
        return links(inLine: line).first { NSLocationInRange(column, $0.range) || (column == NSMaxRange($0.range) && column > $0.range.location && column == (line as NSString).length) }
            .map { link in
                var shifted = link
                shifted.range.location += lineStart
                return shifted
            }
    }

    /// 行内所有链接，按出现顺序；区间相对行首。
    public static func links(inLine line: String) -> [LocatedLink] {
        let units = Array(line.utf16)
        var results: [LocatedLink] = []
        var index = 0

        while index < units.count {
            let unit = units[index]
            if unit == 0x5C { // 反斜杠转义
                index += 2
                continue
            }

            if unit == 0x5B, let link = parseInlineLink(units, bracket: index) {
                results.append(link)
                index = NSMaxRange(link.range)
                continue
            }

            if unit == 0x3C, let autolink = parseAutolink(units, start: index) {
                results.append(autolink)
                index = NSMaxRange(autolink.range)
                continue
            }

            if unit == 0x68, index == 0 || isBoundary(units[index - 1]), let bare = parseBareURL(units, start: index) {
                results.append(bare)
                index = NSMaxRange(bare.range)
                continue
            }

            index += 1
        }
        return results
    }

    private static func parseInlineLink(_ units: [UInt16], bracket: Int) -> LocatedLink? {
        guard let closeBracket = matching(units, open: 0x5B, close: 0x5D, from: bracket),
              closeBracket + 1 < units.count, units[closeBracket + 1] == 0x28,
              let closeParen = matching(units, open: 0x28, close: 0x29, from: closeBracket + 1) else { return nil }

        let isImage = bracket > 0 && units[bracket - 1] == 0x21
        let start = isImage ? bracket - 1 : bracket
        let text = String(decoding: units[(bracket + 1)..<closeBracket], as: UTF16.self)
        let rawDestination = String(decoding: units[(closeBracket + 2)..<closeParen], as: UTF16.self)

        return LocatedLink(
            kind: isImage ? .image : .link,
            range: NSRange(location: start, length: closeParen + 1 - start),
            destination: cleanDestination(rawDestination),
            text: text
        )
    }

    private static func parseAutolink(_ units: [UInt16], start: Int) -> LocatedLink? {
        var end = start + 1
        while end < units.count, units[end] != 0x3E {
            if units[end] == 0x20 || units[end] == 0x3C { return nil }
            end += 1
        }
        guard end < units.count else { return nil }
        let destination = String(decoding: units[(start + 1)..<end], as: UTF16.self)
        let lowercased = destination.lowercased()
        guard ["http://", "https://", "mailto:"].contains(where: lowercased.hasPrefix) else { return nil }
        return LocatedLink(kind: .autolink, range: NSRange(location: start, length: end + 1 - start), destination: destination, text: destination)
    }

    private static func parseBareURL(_ units: [UInt16], start: Int) -> LocatedLink? {
        let prefix = String(decoding: units[start..<min(units.count, start + 8)], as: UTF16.self).lowercased()
        guard prefix.hasPrefix("https://") || prefix.hasPrefix("http://") else { return nil }
        var end = start
        while end < units.count, units[end] != 0x20, units[end] != 0x09, units[end] != 0x3C { end += 1 }
        while end > start, [0x2E, 0x2C, 0x29, 0x3B, 0x3A, 0x21, 0x3F].contains(units[end - 1]) { end -= 1 }
        let destination = String(decoding: units[start..<end], as: UTF16.self)
        return LocatedLink(kind: .bareURL, range: NSRange(location: start, length: end - start), destination: destination, text: destination)
    }

    /// 去掉尖括号与可选标题：`<a b.png> "title"` → `a b.png`。
    static func cleanDestination(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(trimmed[..<space])
        }
        return trimmed
    }

    private static func matching(_ units: [UInt16], open: UInt16, close: UInt16, from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == 0x5C {
                index += 2
                continue
            }
            if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func isBoundary(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x28 || unit >= 0x3000
    }
}
