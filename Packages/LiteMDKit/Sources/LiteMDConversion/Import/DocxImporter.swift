import Foundation

/// Word（.docx）→ Markdown。
///
/// 支持：标题（Heading 1–6 / Title）、段落、粗体 / 斜体 / 删除线 / 高亮 / 行内代码、
/// 超链接、项目符号与编号列表（含层级）、引用、代码块、表格、嵌入图片、换行。
public struct DocxImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, options: ImportOptions = ImportOptions()) throws(ConversionError) -> ConversionResult {
        let archive = try ZipArchive(data: data)
        let documentPath = try Self.mainDocumentPath(archive)
        let document = try XMLTree.parse(try archive.data(for: documentPath))

        let context = Context(
            archive: archive,
            documentPath: documentPath,
            relationships: Relationships.load(for: documentPath, in: archive),
            styles: Self.loadStyles(archive),
            numbering: Self.loadNumbering(archive),
            assets: AssetCollector(options: options)
        )

        guard let body = document.firstDescendant("w:body") else { throw ConversionError.empty }
        var blocks: [String] = []
        var state = BlockState()
        convertBlocks(body.elements, context: context, blocks: &blocks, state: &state)
        state.flush(into: &blocks)

        let markdown = MarkdownComposer.joinBlocks(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
        let title = Self.coreTitle(archive)
        return ConversionResult(markdown: markdown, assets: context.assets.assets, title: title)
    }

    // MARK: Structure

    private struct Context {
        let archive: ZipArchive
        let documentPath: String
        let relationships: Relationships
        let styles: [String: String]
        let numbering: [String: [Int: String]]
        let assets: AssetCollector
    }

    /// 连续的列表项、代码行需要合并成一个块。
    private struct BlockState {
        var listLines: [String] = []
        var listNumberID: String?
        var codeLines: [String] = []

        mutating func flush(into blocks: inout [String]) {
            if !listLines.isEmpty {
                blocks.append(listLines.joined(separator: "\n"))
                listLines = []
                listNumberID = nil
            }
            if !codeLines.isEmpty {
                blocks.append("```\n" + codeLines.joined(separator: "\n") + "\n```")
                codeLines = []
            }
        }
    }

    private func convertBlocks(_ elements: [XElement], context: Context, blocks: inout [String], state: inout BlockState) {
        for element in elements {
            switch element.name {
            case "w:p":
                convertParagraph(element, context: context, blocks: &blocks, state: &state)
            case "w:tbl":
                state.flush(into: &blocks)
                blocks.append(convertTable(element, context: context))
            case "w:sdt":
                if let content = element.child("w:sdtContent") {
                    convertBlocks(content.elements, context: context, blocks: &blocks, state: &state)
                }
            default:
                continue
            }
        }
    }

    private func convertParagraph(_ paragraph: XElement, context: Context, blocks: inout [String], state: inout BlockState) {
        let properties = paragraph.child("w:pPr")
        let styleID = properties?.child("w:pStyle")?["w:val"] ?? ""
        let styleName = (context.styles[styleID] ?? styleID).lowercased()

        // 代码块：Pandoc 使用 “Source Code”，Word 常见 “Code” / “HTML Preformatted”。
        if styleName.contains("source code") || styleName == "code" || styleName.contains("preformatted") {
            if !state.listLines.isEmpty {
                blocks.append(state.listLines.joined(separator: "\n"))
                state.listLines = []
            }
            state.codeLines.append(contentsOf: plainText(paragraph).components(separatedBy: "\n"))
            return
        }

        let inline = MarkdownComposer.render(inlinePieces(paragraph.elements, context: context, link: nil))
            .trimmingCharacters(in: .whitespaces)

        if let numbering = properties?.child("w:numPr"),
           let numID = numbering.child("w:numId")?["w:val"], numID != "0" {
            if !state.codeLines.isEmpty {
                blocks.append("```\n" + state.codeLines.joined(separator: "\n") + "\n```")
                state.codeLines = []
            }
            let level = Int(numbering.child("w:ilvl")?["w:val"] ?? "0") ?? 0
            // 顶层换成另一个编号定义（例如无序列表后紧跟有序列表）时，分成两个列表。
            if level == 0, let previous = state.listNumberID, previous != numID, !state.listLines.isEmpty {
                blocks.append(state.listLines.joined(separator: "\n"))
                state.listLines = []
            }
            if level == 0 { state.listNumberID = numID }
            let format = context.numbering[numID]?[level] ?? "bullet"
            let marker = format == "bullet" || format == "none" ? "-" : "1."
            let indent = String(repeating: "    ", count: max(0, level))
            state.listLines.append(indent + marker + " " + Self.taskMarker(inline))
            return
        }

        state.flush(into: &blocks)
        guard !inline.isEmpty else { return }

        if let level = Self.headingLevel(styleID: styleID, styleName: styleName) {
            blocks.append(String(repeating: "#", count: level) + " " + inline)
        } else if styleName.contains("quote") || styleName == "block text" || styleID.lowercased() == "blocktext" {
            blocks.append("> " + inline.replacingOccurrences(of: "\n", with: "\n> "))
        } else {
            blocks.append(MarkdownComposer.escapeLineStart(inline))
        }
    }

    /// 以 ☒ / ☑ / ☐ 开头的列表项还原为任务列表。
    static func taskMarker(_ text: String) -> String {
        for (symbol, marker) in [("☒", "[x]"), ("☑", "[x]"), ("☐", "[ ]")] where text.hasPrefix(symbol) {
            return marker + " " + text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func headingLevel(styleID: String, styleName: String) -> Int? {
        if styleName == "title" { return 1 }
        for candidate in [styleName, styleID.lowercased()] {
            for prefix in ["heading ", "heading"] where candidate.hasPrefix(prefix) {
                if let level = Int(candidate.dropFirst(prefix.count)), (1...6).contains(level) {
                    return level
                }
            }
        }
        return nil
    }

    private func inlinePieces(_ elements: [XElement], context: Context, link: String?) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        for element in elements {
            switch element.name {
            case "w:r":
                pieces.append(contentsOf: runPieces(element, context: context, link: link))
            case "w:hyperlink":
                var target = link
                if let id = element["r:id"], let relationship = context.relationships.byID[id] {
                    target = relationship.target
                }
                pieces.append(contentsOf: inlinePieces(element.elements, context: context, link: target))
            case "w:ins", "w:smartTag", "w:fldSimple", "w:customXml":
                pieces.append(contentsOf: inlinePieces(element.elements, context: context, link: link))
            case "w:sdt":
                if let content = element.child("w:sdtContent") {
                    pieces.append(contentsOf: inlinePieces(content.elements, context: context, link: link))
                }
            default:
                continue
            }
        }
        return pieces
    }

    private func runPieces(_ run: XElement, context: Context, link: String?) -> [InlinePiece] {
        let properties = run.child("w:rPr")
        func isOn(_ name: String) -> Bool {
            guard let element = properties?.child(name) else { return false }
            let value = element["w:val"]?.lowercased()
            return value == nil || !(value == "0" || value == "false" || value == "none")
        }
        let characterStyle = (properties?.child("w:rStyle")?["w:val"] ?? "").lowercased()
        let isCode = characterStyle.contains("verbatim") || characterStyle.contains("code")
            || (properties?.child("w:rFonts")?["w:ascii"].map { ["courier new", "consolas", "menlo", "monaco"].contains($0.lowercased()) } ?? false)

        var pieces: [InlinePiece] = []
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            var piece = InlinePiece(content: isCode ? .code(text) : .text(text))
            piece.bold = !isCode && isOn("w:b")
            piece.italic = !isCode && isOn("w:i")
            piece.strikethrough = !isCode && (isOn("w:strike") || isOn("w:dstrike"))
            piece.highlight = !isCode && isOn("w:highlight")
            piece.link = link
            pieces.append(piece)
            text = ""
        }

        for element in run.elements {
            switch element.name {
            case "w:t":
                text += element.textContent
            case "w:tab":
                text += "\t"
            case "w:sym":
                // 符号字体字符，例如勾选框 U+2612。
                if let code = element["w:char"].flatMap({ UInt32($0, radix: 16) }) {
                    let value = code >= 0xF000 ? code - 0xF000 : code
                    if let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
                }
            case "w:br", "w:cr":
                flushText()
                pieces.append(.markdown("<br>"))
            case "w:drawing", "w:pict", "w:object":
                flushText()
                for blip in element.descendants("a:blip") + element.descendants("v:imagedata") {
                    guard let id = blip["r:embed"] ?? blip["r:id"],
                          let relationship = context.relationships.byID[id],
                          !relationship.isExternal else { continue }
                    let path = ZipArchive.resolve(relationship.target, relativeTo: context.documentPath)
                    guard let data = try? context.archive.data(for: path) else { continue }
                    let description = element.firstDescendant("wp:docPr")?["descr"] ?? ""
                    let markdownPath = context.assets.add(data, originalName: path, key: path)
                    pieces.append(.markdown("![\(MarkdownComposer.escapeInline(description))](\(MarkdownComposer.destination(markdownPath)))"))
                }
            default:
                continue
            }
        }
        flushText()
        return pieces
    }

    private func plainText(_ paragraph: XElement) -> String {
        var result = ""
        for run in paragraph.descendants("w:r") {
            for element in run.elements {
                switch element.name {
                case "w:t": result += element.textContent
                case "w:tab": result += "\t"
                case "w:br", "w:cr": result += "\n"
                default: continue
                }
            }
        }
        return result
    }

    private func convertTable(_ table: XElement, context: Context) -> String {
        var rows: [[String]] = []
        for row in table.children("w:tr") {
            var cells: [String] = []
            for cell in row.children("w:tc") {
                let paragraphs = cell.descendants("w:p").map { paragraph in
                    MarkdownComposer.render(inlinePieces(paragraph.elements, context: context, link: nil))
                        .trimmingCharacters(in: .whitespaces)
                }
                cells.append(paragraphs.filter { !$0.isEmpty }.joined(separator: "<br>"))
                // 横向合并单元格保持列对齐。
                if let span = Int(cell.child("w:tcPr")?.child("w:gridSpan")?["w:val"] ?? ""), span > 1 {
                    cells.append(contentsOf: Array(repeating: "", count: span - 1))
                }
            }
            rows.append(cells)
        }
        // Markdown 表头本身即为粗体，去掉表头单元格整体包裹的 **。
        if var header = rows.first {
            header = header.map { cell in
                guard cell.count > 4, cell.hasPrefix("**"), cell.hasSuffix("**") else { return cell }
                let inner = String(cell.dropFirst(2).dropLast(2))
                return inner.contains("**") ? cell : inner
            }
            rows[0] = header
        }
        return MarkdownComposer.table(rows)
    }

    // MARK: Package parts

    static func mainDocumentPath(_ archive: ZipArchive) throws(ConversionError) -> String {
        let relationships = Relationships.load(for: "", in: archive)
        if let main = relationships.byID.values.first(where: { $0.type.hasSuffix("/officeDocument") }) {
            return ZipArchive.normalize(main.target)
        }
        if archive.contains("word/document.xml") { return "word/document.xml" }
        throw ConversionError.missingPart("word/document.xml")
    }

    private static func loadStyles(_ archive: ZipArchive) -> [String: String] {
        guard let data = try? archive.data(for: "word/styles.xml"), let root = try? XMLTree.parse(data) else { return [:] }
        var styles: [String: String] = [:]
        for style in root.children("w:style") {
            guard let id = style["w:styleId"] else { continue }
            styles[id] = style.child("w:name")?["w:val"] ?? id
        }
        return styles
    }

    /// numId → (层级 → 编号格式)
    private static func loadNumbering(_ archive: ZipArchive) -> [String: [Int: String]] {
        guard let data = try? archive.data(for: "word/numbering.xml"), let root = try? XMLTree.parse(data) else { return [:] }
        var abstract: [String: [Int: String]] = [:]
        for definition in root.children("w:abstractNum") {
            guard let id = definition["w:abstractNumId"] else { continue }
            var levels: [Int: String] = [:]
            for level in definition.children("w:lvl") {
                guard let index = Int(level["w:ilvl"] ?? "") else { continue }
                levels[index] = level.child("w:numFmt")?["w:val"] ?? "bullet"
            }
            abstract[id] = levels
        }
        var result: [String: [Int: String]] = [:]
        for number in root.children("w:num") {
            guard let id = number["w:numId"], let abstractID = number.child("w:abstractNumId")?["w:val"] else { continue }
            result[id] = abstract[abstractID]
        }
        return result
    }

    private static func coreTitle(_ archive: ZipArchive) -> String? {
        guard let data = try? archive.data(for: "docProps/core.xml"), let root = try? XMLTree.parse(data) else { return nil }
        let title = root.firstDescendant("dc:title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }
}

/// OOXML 关系（`_rels/*.rels`）。
struct Relationships {
    struct Relationship {
        var id: String
        var type: String
        var target: String
        var isExternal: Bool
    }

    var byID: [String: Relationship] = [:]

    /// 读取某个部件对应的关系文件，例如 `word/document.xml` → `word/_rels/document.xml.rels`。
    static func load(for partPath: String, in archive: ZipArchive) -> Relationships {
        let directory = (partPath as NSString).deletingLastPathComponent
        let fileName = (partPath as NSString).lastPathComponent
        let relsPath = directory.isEmpty ? "_rels/\(fileName).rels" : "\(directory)/_rels/\(fileName).rels"
        guard let data = try? archive.data(for: relsPath), let root = try? XMLTree.parse(data) else { return Relationships() }

        var result = Relationships()
        for element in root.children("Relationship") {
            guard let id = element["Id"], let target = element["Target"] else { continue }
            result.byID[id] = Relationship(
                id: id,
                type: element["Type"] ?? "",
                target: target,
                isExternal: element["TargetMode"] == "External"
            )
        }
        return result
    }
}
