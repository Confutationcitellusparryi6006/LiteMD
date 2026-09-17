import Foundation
import LiteMDDomain

/// Markdown 编辑命令的纯函数实现（spec §106–107）。
///
/// 输入正文与选区，输出一次替换与新选区；不接触任何 UI 或文件。
/// 所有平台对同一输入必须得到相同输出（见 `spec/editor-commands.md`）。
public struct EditorEngine: Sendable {
    public var indentUnit: String
    public var listContinuation: Bool

    public init(indentUnit: String = "    ", listContinuation: Bool = true) {
        self.indentUnit = indentUnit
        self.listContinuation = listContinuation
    }

    public func perform(_ command: EditorCommand, text: String, selection: Selection) -> EditResult? {
        let text = text as NSString
        let selection = clamp(selection, length: text.length)

        switch command {
        case .toggleBold:
            return toggleEmphasis(text, selection, strong: true)
        case .toggleItalic:
            return toggleEmphasis(text, selection, strong: false)
        case .toggleStrikethrough:
            return toggleWrap(text, selection, marker: "~~")
        case .toggleInlineCode:
            return toggleWrap(text, selection, marker: "`")
        case .toggleHighlight:
            return toggleWrap(text, selection, marker: "==")
        case .setHeading(let level):
            return setHeading(text, selection, level: max(0, min(6, level)))
        case .toggleQuote:
            return toggleQuote(text, selection)
        case .toggleBulletList:
            return toggleBulletList(text, selection)
        case .toggleNumberedList:
            return toggleNumberedList(text, selection)
        case .toggleTaskList:
            return toggleTaskList(text, selection)
        case .toggleTaskCompletion:
            return toggleTaskCompletion(text, selection)
        case .insertLink(let destination):
            return insertLink(text, selection, destination: destination)
        case .insertImage(let path, let alt):
            let markdown = "![\(alt)](\(MarkdownLineSyntax.linkDestination(path)))"
            return replaceSelection(selection, with: markdown)
        case .insertCodeBlock(let language):
            return insertCodeBlock(text, selection, language: language ?? "")
        case .insertTable(let rows, let columns):
            return insertTable(text, selection, rows: max(1, rows), columns: max(1, columns))
        case .insertHorizontalRule:
            return insertHorizontalRule(text, selection)
        case .indent:
            return indent(text, selection)
        case .outdent:
            return outdent(text, selection)
        case .insertNewline:
            return insertNewline(text, selection)
        }
    }

    // MARK: - Inline

    private func toggleWrap(_ text: NSString, _ selection: Selection, marker: String) -> EditResult {
        let markerLength = marker.utf16.count
        let original = selection.range

        if original.length == 0 {
            let location = original.location
            if location >= markerLength,
               location + markerLength <= text.length,
               text.substring(with: NSRange(location: location - markerLength, length: markerLength)) == marker,
               text.substring(with: NSRange(location: location, length: markerLength)) == marker {
                let edit = TextEdit(range: NSRange(location: location - markerLength, length: markerLength * 2), replacement: "")
                return EditResult(edit: edit, selection: Selection(cursor: location - markerLength))
            }
            let edit = TextEdit(range: original, replacement: marker + marker)
            return EditResult(edit: edit, selection: Selection(cursor: location + markerLength))
        }

        let range = trimmedRange(text, original)
        let selected = text.substring(with: range)
        let selectedLength = range.length

        if selectedLength >= markerLength * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: markerLength, length: selectedLength - markerLength * 2))
            let edit = TextEdit(range: range, replacement: inner)
            return EditResult(edit: edit, selection: Selection(anchor: range.location, head: range.location + inner.utf16.count))
        }

        if range.location >= markerLength,
           NSMaxRange(range) + markerLength <= text.length,
           text.substring(with: NSRange(location: range.location - markerLength, length: markerLength)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(range), length: markerLength)) == marker {
            let outer = NSRange(location: range.location - markerLength, length: selectedLength + markerLength * 2)
            let edit = TextEdit(range: outer, replacement: selected)
            let start = range.location - markerLength
            return EditResult(edit: edit, selection: Selection(anchor: start, head: start + selectedLength))
        }

        let edit = TextEdit(range: range, replacement: marker + selected + marker)
        let start = range.location + markerLength
        return EditResult(edit: edit, selection: Selection(anchor: start, head: start + selectedLength))
    }

    /// `*` / `_` 系列强调。粗体与斜体共享分隔符，需要按连续标记数量判断：
    /// 数量 ≥ 2 表示含粗体，数量为奇数表示含斜体。
    private func toggleEmphasis(_ text: NSString, _ selection: Selection, strong: Bool) -> EditResult {
        let marker = strong ? "**" : "*"
        let removeCount = strong ? 2 : 1
        let original = selection.range

        if original.length == 0 {
            return toggleWrap(text, selection, marker: marker)
        }

        let range = trimmedRange(text, original)
        let selected = text.substring(with: range) as NSString

        func isActive(_ runLength: Int) -> Bool {
            strong ? runLength >= 2 : (runLength == 1 || runLength >= 3)
        }

        // 1. 标记在选区外侧：**[LiteMD]**
        for delimiter: UInt16 in [0x2A, 0x5F] {
            let left = runLength(text, from: range.location - 1, step: -1, of: delimiter)
            let right = runLength(text, from: NSMaxRange(range), step: 1, of: delimiter)
            if isActive(min(left, right)) {
                let outer = NSRange(location: range.location - removeCount, length: range.length + removeCount * 2)
                let edit = TextEdit(range: outer, replacement: selected as String)
                let start = range.location - removeCount
                return EditResult(edit: edit, selection: Selection(anchor: start, head: start + range.length))
            }
        }

        // 2. 标记在选区内侧：[**LiteMD**]
        for delimiter: UInt16 in [0x2A, 0x5F] {
            let left = runLength(selected, from: 0, step: 1, of: delimiter)
            let right = runLength(selected, from: selected.length - 1, step: -1, of: delimiter)
            let run = min(left, right)
            if left + right < selected.length, isActive(run) {
                let inner = selected.substring(with: NSRange(location: removeCount, length: selected.length - removeCount * 2))
                let edit = TextEdit(range: range, replacement: inner)
                return EditResult(edit: edit, selection: Selection(anchor: range.location, head: range.location + inner.utf16.count))
            }
        }

        let edit = TextEdit(range: range, replacement: marker + (selected as String) + marker)
        let start = range.location + marker.utf16.count
        return EditResult(edit: edit, selection: Selection(anchor: start, head: start + range.length))
    }

    private func runLength(_ text: NSString, from start: Int, step: Int, of unit: UInt16) -> Int {
        var count = 0
        var index = start
        while index >= 0, index < text.length, text.character(at: index) == unit {
            count += 1
            index += step
        }
        return count
    }

    /// 去掉选区首尾空白，避免生成 `**LiteMD **` 这类无效强调。全为空白时保持原样。
    private func trimmedRange(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
        return start == end ? range : NSRange(location: start, length: end - start)
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x3000
    }

    // MARK: - Line based

    private struct LineChange {
        var text: String
        var oldPrefix: Int
        var newPrefix: Int

        static func unchanged(_ line: String) -> LineChange {
            LineChange(text: line, oldPrefix: 0, newPrefix: 0)
        }
    }

    private func setHeading(_ text: NSString, _ selection: Selection, level: Int) -> EditResult? {
        transformLines(text, selection) { lines in
            let parsed = lines.map(MarkdownLineSyntax.parseHeadingPrefix)
            let nonEmpty = lines.indices.filter { !MarkdownLineSyntax.isBlankLine(lines[$0]) }
            let alreadyAtLevel = !nonEmpty.isEmpty && nonEmpty.allSatisfy { parsed[$0]?.level == level }
            let target = alreadyAtLevel ? 0 : level
            let prefix = target > 0 ? String(repeating: "#", count: target) + " " : ""

            return lines.enumerated().map { index, line in
                if lines.count > 1, MarkdownLineSyntax.isBlankLine(line) { return .unchanged(line) }
                let oldPrefix = parsed[index]?.length ?? 0
                let content = String(decoding: Array(line.utf16)[oldPrefix...], as: UTF16.self)
                return LineChange(text: prefix + content, oldPrefix: oldPrefix, newPrefix: prefix.utf16.count)
            }
        }
    }

    private func toggleQuote(_ text: NSString, _ selection: Selection) -> EditResult? {
        transformLines(text, selection) { lines in
            let nonEmpty = lines.filter { !MarkdownLineSyntax.isBlankLine($0) }
            let allQuoted = !nonEmpty.isEmpty && nonEmpty.allSatisfy { MarkdownLineSyntax.parseQuotePrefix($0) != nil }

            return lines.map { line in
                if allQuoted {
                    guard let prefix = MarkdownLineSyntax.parseQuotePrefix(line) else { return .unchanged(line) }
                    let content = String(decoding: Array(line.utf16)[prefix...], as: UTF16.self)
                    return LineChange(text: content, oldPrefix: prefix, newPrefix: 0)
                }
                if MarkdownLineSyntax.isBlankLine(line), lines.count > 1 {
                    return LineChange(text: ">", oldPrefix: 0, newPrefix: 1)
                }
                return LineChange(text: "> " + line, oldPrefix: 0, newPrefix: 2)
            }
        }
    }

    private func toggleBulletList(_ text: NSString, _ selection: Selection) -> EditResult? {
        transformLines(text, selection) { lines in
            let parsed = lines.map(MarkdownLineSyntax.parseListPrefix)
            let nonEmpty = lines.indices.filter { !MarkdownLineSyntax.isBlankLine(lines[$0]) || parsed[$0] != nil }
            let allBullets = !nonEmpty.isEmpty && nonEmpty.allSatisfy { index in
                guard let prefix = parsed[index], prefix.task == nil else { return false }
                if case .bullet = prefix.kind { return true }
                return false
            }

            return lines.enumerated().map { index, line in
                if lines.count > 1, MarkdownLineSyntax.isBlankLine(line), parsed[index] == nil { return .unchanged(line) }
                let (indent, oldPrefix) = indentAndPrefix(line, parsed[index])
                let content = String(decoding: Array(line.utf16)[oldPrefix...], as: UTF16.self)
                if allBullets {
                    return LineChange(text: indent + content, oldPrefix: oldPrefix, newPrefix: indent.utf16.count)
                }
                let newPrefix = indent + "- "
                return LineChange(text: newPrefix + content, oldPrefix: oldPrefix, newPrefix: newPrefix.utf16.count)
            }
        }
    }

    private func toggleNumberedList(_ text: NSString, _ selection: Selection) -> EditResult? {
        transformLines(text, selection) { lines in
            let parsed = lines.map(MarkdownLineSyntax.parseListPrefix)
            let nonEmpty = lines.indices.filter { !MarkdownLineSyntax.isBlankLine(lines[$0]) || parsed[$0] != nil }
            let allOrdered = !nonEmpty.isEmpty && nonEmpty.allSatisfy { index in
                guard let prefix = parsed[index], prefix.task == nil else { return false }
                if case .ordered = prefix.kind { return true }
                return false
            }

            var number = 0
            return lines.enumerated().map { index, line in
                if lines.count > 1, MarkdownLineSyntax.isBlankLine(line), parsed[index] == nil { return .unchanged(line) }
                let (indent, oldPrefix) = indentAndPrefix(line, parsed[index])
                let content = String(decoding: Array(line.utf16)[oldPrefix...], as: UTF16.self)
                if allOrdered {
                    return LineChange(text: indent + content, oldPrefix: oldPrefix, newPrefix: indent.utf16.count)
                }
                number += 1
                let newPrefix = indent + "\(number). "
                return LineChange(text: newPrefix + content, oldPrefix: oldPrefix, newPrefix: newPrefix.utf16.count)
            }
        }
    }

    private func toggleTaskList(_ text: NSString, _ selection: Selection) -> EditResult? {
        transformLines(text, selection) { lines in
            let parsed = lines.map(MarkdownLineSyntax.parseListPrefix)
            let nonEmpty = lines.indices.filter { !MarkdownLineSyntax.isBlankLine(lines[$0]) || parsed[$0] != nil }
            let allTasks = !nonEmpty.isEmpty && nonEmpty.allSatisfy { parsed[$0]?.task != nil }

            return lines.enumerated().map { index, line in
                if lines.count > 1, MarkdownLineSyntax.isBlankLine(line), parsed[index] == nil { return .unchanged(line) }
                let (indent, oldPrefix) = indentAndPrefix(line, parsed[index])
                let content = String(decoding: Array(line.utf16)[oldPrefix...], as: UTF16.self)
                if allTasks {
                    return LineChange(text: indent + content, oldPrefix: oldPrefix, newPrefix: indent.utf16.count)
                }
                var marker = "-"
                if let prefix = parsed[index], case .bullet(let character) = prefix.kind {
                    marker = String(character)
                }
                let newPrefix = indent + marker + " [ ] "
                return LineChange(text: newPrefix + content, oldPrefix: oldPrefix, newPrefix: newPrefix.utf16.count)
            }
        }
    }

    /// 选区内有未完成任务时全部勾选，否则全部取消勾选。前缀长度不变，选区保持原位。
    private func toggleTaskCompletion(_ text: NSString, _ selection: Selection) -> EditResult? {
        transformLines(text, selection) { lines in
            let parsed = lines.map(MarkdownLineSyntax.parseListPrefix)
            let tasks = parsed.compactMap { $0?.task }
            guard !tasks.isEmpty else { return lines.map(LineChange.unchanged) }
            let markChecked = tasks.contains(.unchecked)

            return lines.enumerated().map { index, line in
                guard let prefix = parsed[index], prefix.task != nil else { return .unchanged(line) }
                let string = line as NSString
                let searchRange = NSRange(location: prefix.indentLength, length: prefix.length - prefix.indentLength)
                let box = string.range(of: "[", options: [], range: searchRange)
                guard box.location != NSNotFound else { return .unchanged(line) }
                let updated = string.replacingCharacters(in: NSRange(location: box.location + 1, length: 1), with: markChecked ? "x" : " ")
                return .unchanged(updated)
            }
        }
    }

    /// 已是列表时返回列表缩进与完整前缀长度；否则把行首空白视为缩进。
    private func indentAndPrefix(_ line: String, _ prefix: MarkdownLineSyntax.ListPrefix?) -> (String, Int) {
        if let prefix {
            return (prefix.indent, prefix.length)
        }
        let length = MarkdownLineSyntax.leadingWhitespaceLength(line)
        return (String(decoding: Array(line.utf16)[..<length], as: UTF16.self), length)
    }

    private func indent(_ text: NSString, _ selection: Selection) -> EditResult? {
        let unit = indentUnit
        return transformLines(text, selection) { lines in
            lines.map { line in
                if lines.count > 1, MarkdownLineSyntax.isBlankLine(line) { return .unchanged(line) }
                return LineChange(text: unit + line, oldPrefix: 0, newPrefix: unit.utf16.count)
            }
        }
    }

    private func outdent(_ text: NSString, _ selection: Selection) -> EditResult? {
        let maxSpaces = indentUnit == "\t" ? 4 : max(1, indentUnit.utf16.count)
        return transformLines(text, selection) { lines in
            lines.map { line in
                let units = Array(line.utf16)
                var removed = 0
                if units.first == 0x09 {
                    removed = 1
                } else {
                    while removed < units.count, removed < maxSpaces, units[removed] == 0x20 { removed += 1 }
                }
                let content = String(decoding: units[removed...], as: UTF16.self)
                return LineChange(text: content, oldPrefix: removed, newPrefix: 0)
            }
        }
    }

    private func transformLines(_ text: NSString, _ selection: Selection, _ transform: ([String]) -> [LineChange]) -> EditResult? {
        let block = lineBlock(text, selection)
        let lines = text.substring(with: block).components(separatedBy: "\n")
        let changes = transform(lines)
        precondition(changes.count == lines.count, "行变换必须一一对应")

        let replacement = changes.map(\.text).joined(separator: "\n")
        guard replacement != text.substring(with: block) else { return nil }

        var oldStarts: [Int] = []
        var position = block.location
        for line in lines {
            oldStarts.append(position)
            position += line.utf16.count + 1
        }
        var newStarts: [Int] = []
        position = block.location
        for change in changes {
            newStarts.append(position)
            position += change.text.utf16.count + 1
        }
        let delta = replacement.utf16.count - block.length

        func map(_ offset: Int) -> Int {
            if offset < block.location { return offset }
            if offset > NSMaxRange(block) { return offset + delta }
            var lineIndex = 0
            for (index, start) in oldStarts.enumerated() where start <= offset {
                lineIndex = index
            }
            let column = offset - oldStarts[lineIndex]
            let change = changes[lineIndex]
            let newColumn = column >= change.oldPrefix ? column - change.oldPrefix + change.newPrefix : change.newPrefix
            return newStarts[lineIndex] + min(newColumn, change.text.utf16.count)
        }

        let newSelection = Selection(anchor: map(selection.anchor), head: map(selection.head))
        return EditResult(edit: TextEdit(range: block, replacement: replacement), selection: newSelection)
    }

    /// 选区覆盖的完整行区间（不含最后的换行符）。
    /// 选区恰好结束在下一行行首时，不包含那一行。
    private func lineBlock(_ text: NSString, _ selection: Selection) -> NSRange {
        var range = selection.range
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A {
            range.length -= 1
        }
        let start = lineStart(text, range.location)
        let end = lineEnd(text, NSMaxRange(range))
        return NSRange(location: start, length: end - start)
    }

    private func lineStart(_ text: NSString, _ location: Int) -> Int {
        var index = location
        while index > 0, text.character(at: index - 1) != 0x0A { index -= 1 }
        return index
    }

    private func lineEnd(_ text: NSString, _ location: Int) -> Int {
        var index = location
        while index < text.length, text.character(at: index) != 0x0A { index += 1 }
        return index
    }

    // MARK: - Insertions

    private func replaceSelection(_ selection: Selection, with string: String) -> EditResult {
        let range = selection.range
        return EditResult(
            edit: TextEdit(range: range, replacement: string),
            selection: Selection(cursor: range.location + string.utf16.count)
        )
    }

    private func insertLink(_ text: NSString, _ selection: Selection, destination: String?) -> EditResult {
        let range = selection.range
        let selected = text.substring(with: range)
        let location = range.location

        if let destination {
            let formatted = MarkdownLineSyntax.linkDestination(destination)
            if selected.isEmpty {
                let markdown = "[](\(formatted))"
                return EditResult(edit: TextEdit(range: range, replacement: markdown), selection: Selection(cursor: location + 1))
            }
            return replaceSelection(selection, with: "[\(selected)](\(formatted))")
        }

        let lowercased = selected.lowercased()
        if ["http://", "https://", "mailto:"].contains(where: lowercased.hasPrefix) {
            let markdown = "[](\(selected))"
            return EditResult(edit: TextEdit(range: range, replacement: markdown), selection: Selection(cursor: location + 1))
        }
        if selected.isEmpty {
            return EditResult(edit: TextEdit(range: range, replacement: "[]()"), selection: Selection(cursor: location + 1))
        }
        let markdown = "[\(selected)]()"
        return EditResult(
            edit: TextEdit(range: range, replacement: markdown),
            selection: Selection(cursor: location + selected.utf16.count + 3)
        )
    }

    private func insertCodeBlock(_ text: NSString, _ selection: Selection, language: String) -> EditResult {
        let fenceOpen = "```" + language
        let languageLength = language.utf16.count

        if selection.range.length > 0 {
            let block = lineBlock(text, selection)
            let content = text.substring(with: block)
            let replacement = fenceOpen + "\n" + content + "\n```"
            return EditResult(
                edit: TextEdit(range: block, replacement: replacement),
                selection: Selection(cursor: block.location + 3 + languageLength)
            )
        }

        let location = selection.head
        let start = lineStart(text, location)
        let end = lineEnd(text, location)
        let line = text.substring(with: NSRange(location: start, length: end - start))

        if MarkdownLineSyntax.isBlankLine(line) {
            let replacement = fenceOpen + "\n\n```"
            return EditResult(
                edit: TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement),
                selection: Selection(cursor: start + 3 + languageLength + 1)
            )
        }
        let replacement = "\n" + fenceOpen + "\n\n```"
        return EditResult(
            edit: TextEdit(range: NSRange(location: end, length: 0), replacement: replacement),
            selection: Selection(cursor: end + 1 + 3 + languageLength + 1)
        )
    }

    private func insertTable(_ text: NSString, _ selection: Selection, rows: Int, columns: Int) -> EditResult {
        let headers = (1...columns).map { "Column \($0)" }
        let header = "| " + headers.joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "|" + String(repeating: "  |", count: columns)
        let table = ([header, delimiter] + Array(repeating: row, count: rows)).joined(separator: "\n")

        let location = selection.head
        let start = lineStart(text, location)
        let end = lineEnd(text, location)
        let line = text.substring(with: NSRange(location: start, length: end - start))

        let insertion: TextEdit
        let tableStart: Int
        if MarkdownLineSyntax.isBlankLine(line) {
            insertion = TextEdit(range: NSRange(location: start, length: end - start), replacement: table)
            tableStart = start
        } else {
            insertion = TextEdit(range: NSRange(location: end, length: 0), replacement: "\n\n" + table)
            tableStart = end + 2
        }
        // 选中第一个表头，方便直接输入。
        let firstHeaderStart = tableStart + 2
        return EditResult(
            edit: insertion,
            selection: Selection(anchor: firstHeaderStart, head: firstHeaderStart + headers[0].utf16.count)
        )
    }

    private func insertHorizontalRule(_ text: NSString, _ selection: Selection) -> EditResult {
        let location = selection.head
        let start = lineStart(text, location)
        let end = lineEnd(text, location)
        let line = text.substring(with: NSRange(location: start, length: end - start))

        if MarkdownLineSyntax.isBlankLine(line) {
            let replacement = "---\n"
            return EditResult(
                edit: TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement),
                selection: Selection(cursor: start + replacement.utf16.count)
            )
        }
        let replacement = "\n\n---\n"
        return EditResult(
            edit: TextEdit(range: NSRange(location: end, length: 0), replacement: replacement),
            selection: Selection(cursor: end + replacement.utf16.count)
        )
    }

    // MARK: - Newline

    private func insertNewline(_ text: NSString, _ selection: Selection) -> EditResult? {
        guard listContinuation else { return nil }
        let range = selection.range
        let start = lineStart(text, range.location)
        let end = lineEnd(text, range.location)
        guard NSMaxRange(range) <= end else { return nil }
        guard !MarkdownLineSyntax.isInsideFencedCodeBlock(text, location: start) else { return nil }

        let line = text.substring(with: NSRange(location: start, length: end - start))
        let column = range.location - start
        let trailing = text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))

        if let list = MarkdownLineSyntax.parseListPrefix(line) {
            guard column >= list.length else { return nil }
            let content = String(decoding: Array(line.utf16)[list.length...], as: UTF16.self)
            let lineRange = NSRange(location: start, length: end - start)

            if MarkdownLineSyntax.isBlankLine(content), MarkdownLineSyntax.isBlankLine(trailing) {
                // 空列表项回车：有缩进则减少一级，否则结束列表。
                if list.indentLength > 0 {
                    let outdentLength = list.indent.hasPrefix("\t") ? 1 : min(list.indentLength, max(1, indentUnit == "\t" ? 4 : indentUnit.utf16.count))
                    let newLine = String(decoding: Array(line.utf16)[outdentLength...], as: UTF16.self)
                    return EditResult(
                        edit: TextEdit(range: lineRange, replacement: newLine),
                        selection: Selection(cursor: start + newLine.utf16.count)
                    )
                }
                return EditResult(edit: TextEdit(range: lineRange, replacement: ""), selection: Selection(cursor: start))
            }

            var nextPrefix = list.indent
            switch list.kind {
            case .bullet(let marker):
                nextPrefix += "\(marker) "
            case .ordered(let number, let delimiter):
                nextPrefix += "\(number + 1)\(delimiter) "
            }
            if list.task != nil {
                nextPrefix += "[ ] "
            }
            let insertion = "\n" + nextPrefix
            return EditResult(
                edit: TextEdit(range: range, replacement: insertion),
                selection: Selection(cursor: range.location + insertion.utf16.count)
            )
        }

        if let quoteLength = MarkdownLineSyntax.parseNestedQuotePrefix(line) {
            guard column >= quoteLength else { return nil }
            let content = String(decoding: Array(line.utf16)[quoteLength...], as: UTF16.self)
            if MarkdownLineSyntax.isBlankLine(content), MarkdownLineSyntax.isBlankLine(trailing) {
                let lineRange = NSRange(location: start, length: end - start)
                return EditResult(edit: TextEdit(range: lineRange, replacement: ""), selection: Selection(cursor: start))
            }
            var prefix = String(decoding: Array(line.utf16)[..<quoteLength], as: UTF16.self)
            if !prefix.hasSuffix(" ") { prefix += " " }
            let insertion = "\n" + prefix
            return EditResult(
                edit: TextEdit(range: range, replacement: insertion),
                selection: Selection(cursor: range.location + insertion.utf16.count)
            )
        }

        return nil
    }

    private func clamp(_ selection: Selection, length: Int) -> Selection {
        Selection(anchor: max(0, min(selection.anchor, length)), head: max(0, min(selection.head, length)))
    }
}
