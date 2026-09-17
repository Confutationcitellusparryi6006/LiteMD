import AppKit
import LiteMDConversion
import PDFKit
import Vision

/// 依赖系统框架的导入：PDF（PDFKit）、图片文字识别（Vision）、RTF / DOC / ODT（AppKit 文本系统）。
enum SystemImporters {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "odt", "webarchive", "wordml"]

    /// 导入面板中允许选择的全部扩展名。
    static var supportedExtensions: [String] {
        let builtIn = ["docx", "pptx", "xlsx", "epub", "html", "htm", "csv", "tsv", "json", "xml", "txt"]
        return builtIn + ["pdf"] + imageExtensions.sorted() + richTextExtensions.sorted() + AudioTranscriber.audioExtensions.sorted()
    }

    static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: PDF

    static func importPDF(at url: URL) throws -> ConversionResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.corrupted("Could not open PDF")
        }
        var blocks: [String] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            blocks.append(contentsOf: paragraphs(fromPDFText: text))
        }
        let markdown = MarkdownComposer.joinBlocks(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 扫描版 PDF 没有文字层。
            throw ConversionError.empty
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return ConversionResult(markdown: markdown, title: title?.isEmpty == false ? title : url.deletingPathExtension().lastPathComponent)
    }

    /// PDF 文字按行排列。合并被排版折断的行：中日韩文字之间直接连接，其他文字之间补空格；
    /// 行尾连字符拆开的英文单词重新拼合；句末标点且明显短于常规行宽时视为段落结束。
    static func paragraphs(fromPDFText text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let typicalLength = lines.map(\.count).max() ?? 0
        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                paragraphs.append(MarkdownComposer.escapeLineStart(MarkdownComposer.escapeInline(trimmed)))
            }
            current = ""
        }

        for line in lines {
            guard !line.isEmpty else {
                flush()
                continue
            }
            if let bullet = line.first, "•◦▪●‣–".contains(bullet) {
                flush()
                let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
                paragraphs.append("- " + MarkdownComposer.escapeInline(content))
                continue
            }

            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current.removeLast()
                current += line
            } else if let last = current.last, let first = line.first, isCJK(last) || isCJK(first) {
                current += line
            } else {
                current += " " + line
            }

            if let last = line.last, ".。!?！？:：".contains(last), line.count < typicalLength * 85 / 100 {
                flush()
            }
        }
        flush()
        return paragraphs
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    // MARK: Images

    /// 图片保存为资源，并用 Vision 识别其中的文字（支持中英日韩）。
    static func importImage(at url: URL, options: ImportOptions) async throws -> ConversionResult {
        let data = try Data(contentsOf: url)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].map { Locale.Language(identifier: $0) }
        let observations = (try? await request.perform(on: url)) ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }

        let fileExtension = url.pathExtension.lowercased()
        let fileName = "\(options.assetPrefix).\(fileExtension == "jpeg" ? "jpg" : fileExtension)"
        let path = options.assetDirectory.isEmpty ? fileName : "\(options.assetDirectory)/\(fileName)"
        let alt = MarkdownComposer.escapeInline(url.deletingPathExtension().lastPathComponent)

        var blocks = ["![\(alt)](\(MarkdownComposer.destination(path)))"]
        blocks.append(contentsOf: lines.map { MarkdownComposer.escapeLineStart(MarkdownComposer.escapeInline($0)) })
        return ConversionResult(
            markdown: MarkdownComposer.joinBlocks(blocks),
            assets: [ConvertedAsset(fileName: fileName, data: data)],
            title: url.deletingPathExtension().lastPathComponent
        )
    }

    // MARK: Rich text

    @MainActor
    static func importRichText(at url: URL) throws -> ConversionResult {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let markdown = AttributedMarkdownConverter.convert(attributed)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
        return ConversionResult(markdown: markdown, title: url.deletingPathExtension().lastPathComponent)
    }
}

/// NSAttributedString → Markdown：粗体 / 斜体 / 删除线 / 链接按属性映射，
/// 标题按相对正文的字号推断，列表来自段落样式中的 NSTextList。
enum AttributedMarkdownConverter {
    static func convert(_ attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        let bodySize = dominantFontSize(attributed)
        var blocks: [String] = []
        var listLines: [String] = []

        func flushList() {
            if !listLines.isEmpty {
                blocks.append(listLines.joined(separator: "\n"))
                listLines = []
            }
        }

        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)

            var contentRange = paragraphRange
            while contentRange.length > 0, CharacterSet.newlines.contains(UnicodeScalar(string.character(at: NSMaxRange(contentRange) - 1)) ?? " ") {
                contentRange.length -= 1
            }
            guard contentRange.length > 0 else {
                flushList()
                continue
            }

            let style = attributed.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle
            if let lists = style?.textLists, let list = lists.last {
                // 富文本中的列表标记本身也是文字（例如 “\t•\t”），需要去掉。
                var text = pieces(attributed, in: contentRange)
                text = stripListMarker(text)
                let ordered = list.markerFormat.rawValue.contains("decimal")
                    || list.markerFormat.rawValue.contains("roman")
                    || list.markerFormat.rawValue.contains("alpha")
                listLines.append(String(repeating: "    ", count: max(0, lists.count - 1)) + (ordered ? "1. " : "- ") + text)
                continue
            }
            flushList()

            let text = pieces(attributed, in: contentRange)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let size = maximumFontSize(attributed, in: contentRange)
            let isShort = contentRange.length <= 120

            if isShort, size >= bodySize * 1.6 {
                blocks.append("# " + stripEmphasis(text))
            } else if isShort, size >= bodySize * 1.3 {
                blocks.append("## " + stripEmphasis(text))
            } else if isShort, size >= bodySize * 1.1, isEntirelyBold(attributed, in: contentRange) {
                blocks.append("### " + stripEmphasis(text))
            } else {
                blocks.append(MarkdownComposer.escapeLineStart(text))
            }
        }
        flushList()
        return MarkdownComposer.joinBlocks(blocks)
    }

    private static func pieces(_ attributed: NSAttributedString, in range: NSRange) -> String {
        var pieces: [InlinePiece] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
            var piece = InlinePiece.text(text)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                piece.bold = traits.contains(.bold)
                piece.italic = traits.contains(.italic)
                if traits.contains(.monoSpace) {
                    piece.content = .code(text)
                    piece.bold = false
                    piece.italic = false
                }
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                piece.strikethrough = true
            }
            if let link = attributes[.link] {
                piece.link = (link as? URL)?.absoluteString ?? (link as? String)
            }
            pieces.append(piece)
        }
        return MarkdownComposer.render(pieces).trimmingCharacters(in: .whitespaces)
    }

    private static func dominantFontSize(_ attributed: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            weights[font.pointSize, default: 0] += range.length
        }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    private static func maximumFontSize(_ attributed: NSAttributedString, in range: NSRange) -> CGFloat {
        var size: CGFloat = 0
        attributed.enumerateAttribute(.font, in: range) { value, _, _ in
            if let font = value as? NSFont { size = max(size, font.pointSize) }
        }
        return size
    }

    private static func isEntirelyBold(_ attributed: NSAttributedString, in range: NSRange) -> Bool {
        var bold = true
        attributed.enumerateAttribute(.font, in: range) { value, subrange, stop in
            let text = (attributed.string as NSString).substring(with: subrange)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { return }
            bold = false
            stop.pointee = true
        }
        return bold
    }

    private static func stripEmphasis(_ text: String) -> String {
        var result = text
        for marker in ["***", "**", "*"] where result.hasPrefix(marker) && result.hasSuffix(marker) && result.count > marker.count * 2 {
            result = String(result.dropFirst(marker.count).dropLast(marker.count))
            break
        }
        return result
    }

    private static func stripListMarker(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, first == "\t" || first == " " { result = result.dropFirst() }
        if let tab = result.firstIndex(of: "\t"), result.distance(from: result.startIndex, to: tab) <= 6 {
            result = result[result.index(after: tab)...]
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }
}
