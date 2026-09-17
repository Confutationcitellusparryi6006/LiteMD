import Foundation
import Markdown

/// 把 Markdown 转为纯文本（右键 “Copy As › Plain Text”）：去掉语法标记，保留段落与列表结构。
struct PlainTextRenderer: MarkupVisitor {
    typealias Result = Void

    private(set) var output = ""
    private var listDepth = 0
    private var orderedCounters: [UInt?] = []
    private var isAtListItemStart = false

    mutating func defaultVisit(_ markup: Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    private mutating func startBlock() {
        if isAtListItemStart {
            isAtListItemStart = false
            return
        }
        guard !output.isEmpty else { return }
        if listDepth > 0 {
            if !output.hasSuffix("\n") { output += "\n" }
        } else {
            while !output.hasSuffix("\n\n") { output += "\n" }
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        startBlock()
        defaultVisit(paragraph)
    }

    mutating func visitHeading(_ heading: Heading) {
        startBlock()
        defaultVisit(heading)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        defaultVisit(blockQuote)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        startBlock()
        var code = codeBlock.code
        while code.hasSuffix("\n") { code.removeLast() }
        output += code
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        startBlock()
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {}

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        startBlock()
        listDepth += 1
        orderedCounters.append(nil)
        defaultVisit(unorderedList)
        orderedCounters.removeLast()
        listDepth -= 1
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        startBlock()
        listDepth += 1
        orderedCounters.append(orderedList.startIndex)
        defaultVisit(orderedList)
        orderedCounters.removeLast()
        listDepth -= 1
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        output += String(repeating: "    ", count: max(0, listDepth - 1))
        if let number = orderedCounters.last ?? nil {
            output += "\(number). "
            orderedCounters[orderedCounters.count - 1] = number + 1
        } else {
            switch listItem.checkbox {
            case .checked: output += "☑ "
            case .unchecked: output += "☐ "
            case nil: output += "• "
            }
        }
        isAtListItemStart = true
        defaultVisit(listItem)
        isAtListItemStart = false
    }

    mutating func visitTable(_ table: Table) {
        startBlock()
        var rows: [String] = []
        var head = PlainTextRenderer()
        rows.append(table.head.cells.map { cell -> String in
            head.output = ""
            head.defaultVisit(cell)
            return head.output
        }.joined(separator: "\t"))
        for row in table.body.rows {
            var renderer = PlainTextRenderer()
            rows.append(row.cells.map { cell -> String in
                renderer.output = ""
                renderer.defaultVisit(cell)
                return renderer.output
            }.joined(separator: "\t"))
        }
        output += rows.joined(separator: "\n")
    }

    mutating func visitText(_ text: Markdown.Text) {
        output += HTMLRenderer.renderHighlights(text.string)
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        output += inlineCode.code
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        output += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        output += "\n"
    }

    mutating func visitImage(_ image: Image) {
        output += image.plainText
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {}

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        output += symbolLink.destination ?? ""
    }
}

extension MarkdownParser {
    /// 去掉 Markdown 语法后的纯文本。
    public func plainText(from markdown: String) -> String {
        let frontMatter = FrontMatter.split(markdown)
        let document = Document(parsing: frontMatter.body, options: [.disableSmartOpts])
        var renderer = PlainTextRenderer()
        renderer.visit(document)
        return renderer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// EPUB 等场景使用的 XHTML 片段。
    public func xhtmlFragment(from markdown: String) -> String {
        let frontMatter = FrontMatter.split(markdown)
        let document = Document(parsing: frontMatter.body, options: [.disableSmartOpts])
        var renderer = HTMLRenderer(lineStartOffsets: [0], fileURLPrefix: nil, includesSourceLines: false)
        renderer.xhtml = true
        renderer.visit(document)
        return renderer.output
    }

    /// 可粘贴到其他应用的 HTML 片段（已净化，不含 `data-line`）。
    public func htmlFragment(from markdown: String) -> String {
        let frontMatter = FrontMatter.split(markdown)
        let document = Document(parsing: frontMatter.body, options: [.disableSmartOpts])
        var renderer = HTMLRenderer(lineStartOffsets: [0], fileURLPrefix: nil, includesSourceLines: false)
        renderer.visit(document)
        return renderer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
