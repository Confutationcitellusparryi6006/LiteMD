import Foundation

/// 内置导入格式。PDF、图片（OCR）、RTF / DOC / ODT 依赖系统框架，由平台层实现。
public enum ImportFormat: String, CaseIterable, Sendable {
    case docx
    case pptx
    case xlsx
    case epub
    case html
    case csv
    case json
    case xml
    case text

    public static func format(forExtension fileExtension: String) -> ImportFormat? {
        switch fileExtension.lowercased() {
        case "docx", "docm", "dotx": .docx
        case "pptx", "pptm": .pptx
        case "xlsx", "xlsm": .xlsx
        case "epub": .epub
        case "html", "htm", "xhtml": .html
        case "csv", "tsv": .csv
        case "json": .json
        case "xml": .xml
        case "txt", "text", "log": .text
        default: nil
        }
    }
}

/// 导入入口：按扩展名分发到对应的转换器。
public struct DocumentImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, fileName: String, options: ImportOptions) throws(ConversionError) -> ConversionResult {
        let fileExtension = (fileName as NSString).pathExtension
        guard let format = ImportFormat.format(forExtension: fileExtension) else {
            throw ConversionError.unsupported(fileExtension)
        }
        let title = (fileName as NSString).deletingPathExtension

        switch format {
        case .docx:
            return try DocxImporter().convert(data, options: options)
        case .pptx:
            return try PptxImporter().convert(data, options: options)
        case .xlsx:
            return try XlsxImporter().convert(data, options: options)
        case .epub:
            return try EpubImporter().convert(data, options: options)
        case .html:
            let root = HTMLTagSoupParser.parse(Self.decode(data))
            let converter = HTMLMarkdownConverter()
            let markdown = converter.convert(root)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
            return ConversionResult(markdown: markdown, title: converter.title(of: root) ?? title)
        case .csv:
            return try CsvImporter().convert(Self.decode(data))
        case .json:
            let pretty = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? Self.decode(data)
            return ConversionResult(markdown: "```json\n\(pretty)\n```\n", title: title)
        case .xml:
            return ConversionResult(markdown: "```xml\n\(Self.decode(data).trimmingCharacters(in: .newlines))\n```\n", title: title)
        case .text:
            return ConversionResult(markdown: Self.decode(data), title: title)
        }
    }

    /// UTF-8 优先，失败时依次尝试 UTF-16 与 GB 18030（常见中文编码）。
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 容错的 HTML 解析：真实网页通常不是合法 XML（未闭合标签、空元素、实体）。
public enum HTMLTagSoupParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]
    /// 遇到这些块级开始标签时，自动闭合尚未闭合的 `<p>`。
    static let closesParagraph: Set<String> = ["p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "section", "article", "header", "footer", "hr"]

    public static func parse(_ html: String) -> XElement {
        let root = XElement(name: "html")
        var stack: [XElement] = [root]
        let scalars = Array(html.unicodeScalars)
        var index = 0
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            stack.last?.append(.text(decodeEntities(text)))
            text = ""
        }

        func close(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.localName == name }), position > 0 else { return }
            stack.removeSubrange(position...)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            // 注释与声明
            if starts(scalars, index, "<!--") {
                flushText()
                index = find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                continue
            }
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                flushText()
                index = find(scalars, ">", from: index).map { $0 + 1 } ?? scalars.count
                continue
            }

            guard let tagEnd = find(scalars, ">", from: index) else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            let inner = String(String.UnicodeScalarView(scalars[(index + 1)..<tagEnd]))
            let isClosing = inner.hasPrefix("/")
            let content = isClosing ? String(inner.dropFirst()) : inner
            let name = content.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
            guard let first = name.unicodeScalars.first, first.properties.isAlphabetic else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            flushText()
            index = tagEnd + 1

            if isClosing {
                close(name)
                continue
            }

            if closesParagraph.contains(name), stack.last?.localName == "p" { stack.removeLast() }
            // 可省略闭合标签的元素：遇到同级新元素时自动闭合上一个（不跨越其容器）。
            let implicitClosing: [String: (closes: Set<String>, boundary: Set<String>)] = [
                "li": (["li"], ["ul", "ol"]),
                "td": (["td", "th"], ["tr", "table"]),
                "th": (["td", "th"], ["tr", "table"]),
                "tr": (["tr", "td", "th"], ["table", "thead", "tbody", "tfoot"]),
                "dt": (["dt", "dd"], ["dl"]),
                "dd": (["dt", "dd"], ["dl"]),
                "option": (["option"], ["select"]),
            ]
            if let rule = implicitClosing[name],
               let open = stack.lastIndex(where: { rule.closes.contains($0.localName) }),
               !stack[(open + 1)...].contains(where: { rule.boundary.contains($0.localName) }),
               open > 0 {
                stack.removeSubrange(open...)
            }

            let element = XElement(name: name, attributes: parseAttributes(String(content.dropFirst(name.count))))
            stack.last?.append(.element(element))

            if rawTextElements.contains(name) {
                let closing = "</\(name)"
                let end = findCaseInsensitive(scalars, closing, from: index) ?? scalars.count
                element.append(.text(String(String.UnicodeScalarView(scalars[index..<end]))))
                index = find(scalars, ">", from: end).map { $0 + 1 } ?? scalars.count
                continue
            }
            if !voidElements.contains(name), !content.hasSuffix("/") {
                stack.append(element)
            }
        }
        flushText()
        return root
    }

    static func parseAttributes(_ source: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let scalars = Array(source.unicodeScalars)
        var index = 0
        while index < scalars.count {
            while index < scalars.count, scalars[index].properties.isWhitespace || scalars[index] == "/" { index += 1 }
            var name = ""
            while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != "=", scalars[index] != "/" {
                name.unicodeScalars.append(scalars[index])
                index += 1
            }
            guard !name.isEmpty else { break }
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
            var value = ""
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    while index < scalars.count, scalars[index] != quote {
                        value.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < scalars.count, !scalars[index].properties.isWhitespace {
                        value.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                }
            }
            attributes[name.lowercased()] = decodeEntities(value)
        }
        return attributes
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·", "times": "×"]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].firstIndex(of: ";"), text.distance(from: index, to: semicolon) <= 10 {
                let entity = String(text[text.index(after: index)..<semicolon])
                var replacement: String?
                if let value = named[entity] {
                    replacement = value
                } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(scalar)
                } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(scalar)
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func starts(_ scalars: [Unicode.Scalar], _ index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.unicodeScalars)
        guard index + pattern.count <= scalars.count else { return false }
        return scalars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private static func find(_ scalars: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        var index = start
        while index < scalars.count {
            if starts(scalars, index, literal) { return index }
            index += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ scalars: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        let pattern = Array(literal.lowercased().unicodeScalars)
        var index = start
        while index + pattern.count <= scalars.count {
            var matched = true
            for offset in 0..<pattern.count {
                let value = scalars[index + offset]
                let lowered = (65...90).contains(value.value) ? Unicode.Scalar(value.value + 32)! : value
                if lowered != pattern[offset] {
                    matched = false
                    break
                }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}
