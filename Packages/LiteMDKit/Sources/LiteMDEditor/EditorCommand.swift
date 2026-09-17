import Foundation
import LiteMDDomain

/// Markdown 编辑命令（spec §106）。
///
/// Toolbar、Keyboard、Menu、Command Palette 都只发出命令，
/// 由 `EditorEngine` 统一计算文本变化，保证所有入口行为一致。
public enum EditorCommand: Equatable, Sendable {
    case toggleBold
    case toggleItalic
    case toggleStrikethrough
    case toggleInlineCode
    /// `==高亮==`
    case toggleHighlight
    /// 0 表示转为普通段落。
    case setHeading(level: Int)
    case toggleQuote
    case toggleBulletList
    case toggleNumberedList
    case toggleTaskList
    /// 勾选 / 取消勾选任务：`- [ ]` ↔ `- [x]`。
    case toggleTaskCompletion
    case insertLink(destination: String?)
    case insertImage(path: String, alt: String)
    case insertCodeBlock(language: String?)
    case insertTable(rows: Int, columns: Int)
    case insertHorizontalRule
    case indent
    case outdent
    /// 回车：在列表、任务、引用中自动延续标记。返回 nil 时由平台默认处理。
    case insertNewline
}

/// 一次文本替换。区间单位为 UTF-16。
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// 命令结果：一次替换 + 替换完成后的选区。一次命令对应一次 Undo。
public struct EditResult: Equatable, Sendable {
    public var edit: TextEdit
    public var selection: Selection

    public init(edit: TextEdit, selection: Selection) {
        self.edit = edit
        self.selection = selection
    }

    /// 在纯字符串上应用结果，便于测试与跨平台对照。
    public func applied(to text: String) -> String {
        let string = NSMutableString(string: text)
        string.replaceCharacters(in: edit.range, with: edit.replacement)
        return String(string)
    }
}
