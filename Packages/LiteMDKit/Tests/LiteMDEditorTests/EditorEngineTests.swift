import Foundation
import LiteMDDomain
import LiteMDEditor
import Testing

/// 与 `spec/editor-commands.md` 对应。所有平台必须得到相同结果（spec §149）。
@Suite("EditorEngine")
struct EditorEngineTests {
    let engine = EditorEngine()

    private func run(_ command: EditorCommand, _ text: String, _ anchor: Int, _ head: Int? = nil) -> (String, Selection)? {
        guard let result = engine.perform(command, text: text, selection: Selection(anchor: anchor, head: head ?? anchor)) else {
            return nil
        }
        return (result.applied(to: text), result.selection)
    }

    // MARK: Inline

    @Test func toggleBoldWrapsSelection() throws {
        let (text, selection) = try #require(run(.toggleBold, "LiteMD", 0, 6))
        #expect(text == "**LiteMD**")
        #expect(selection == Selection(anchor: 2, head: 8))
    }

    @Test func toggleBoldUnwrapsWhenMarkersSurroundSelection() throws {
        let (text, selection) = try #require(run(.toggleBold, "**LiteMD**", 2, 8))
        #expect(text == "LiteMD")
        #expect(selection == Selection(anchor: 0, head: 6))
    }

    @Test func toggleBoldUnwrapsWhenSelectionIncludesMarkers() throws {
        let (text, selection) = try #require(run(.toggleBold, "**LiteMD**", 0, 10))
        #expect(text == "LiteMD")
        #expect(selection == Selection(anchor: 0, head: 6))
    }

    @Test func italicInsideBoldAddsEmphasis() throws {
        let (text, selection) = try #require(run(.toggleItalic, "**LiteMD**", 2, 8))
        #expect(text == "***LiteMD***")
        #expect(selection == Selection(anchor: 3, head: 9))

        let (removed, _) = try #require(run(.toggleItalic, text, 3, 9))
        #expect(removed == "**LiteMD**")
    }

    @Test func boldIgnoresSurroundingWhitespaceInSelection() throws {
        let (text, _) = try #require(run(.toggleBold, "a LiteMD b", 1, 9))
        #expect(text == "a **LiteMD** b")
    }

    @Test func boldWithCursorInsertsEmptyPairAndRemovesIt() throws {
        let (text, selection) = try #require(run(.toggleBold, "ab", 1))
        #expect(text == "a****b")
        #expect(selection == Selection(cursor: 3))

        let (removed, cursor) = try #require(run(.toggleBold, text, 3))
        #expect(removed == "ab")
        #expect(cursor == Selection(cursor: 1))
    }

    @Test func inlineCodeAndStrikethrough() throws {
        #expect(try #require(run(.toggleInlineCode, "let x", 0, 5)).0 == "`let x`")
        #expect(try #require(run(.toggleStrikethrough, "old", 0, 3)).0 == "~~old~~")
        #expect(try #require(run(.toggleStrikethrough, "~~old~~", 2, 5)).0 == "old")
        #expect(try #require(run(.toggleHighlight, "key", 0, 3)).0 == "==key==")
        #expect(try #require(run(.toggleHighlight, "==key==", 2, 5)).0 == "key")
    }

    @Test func boldWorksWithChineseAndEmoji() throws {
        let source = "中文😀输入"
        let length = source.utf16.count
        let (text, selection) = try #require(run(.toggleBold, source, 0, length))
        #expect(text == "**中文😀输入**")
        #expect(selection == Selection(anchor: 2, head: 2 + length))
    }

    // MARK: Line based

    @Test func headingSetsTogglesAndReplacesLevel() throws {
        let (h2, cursor) = try #require(run(.setHeading(level: 2), "Title", 5))
        #expect(h2 == "## Title")
        #expect(cursor == Selection(cursor: 8))

        #expect(try #require(run(.setHeading(level: 1), "## Title", 8)).0 == "# Title")
        #expect(try #require(run(.setHeading(level: 2), "## Title", 8)).0 == "Title")
        #expect(try #require(run(.setHeading(level: 0), "### Title", 9)).0 == "Title")
    }

    @Test func headingOnlyAffectsCurrentLine() throws {
        let (text, _) = try #require(run(.setHeading(level: 1), "one\ntwo\nthree", 5))
        #expect(text == "one\n# two\nthree")
    }

    @Test func quoteTogglesAcrossLines() throws {
        let (quoted, _) = try #require(run(.toggleQuote, "a\n\nb", 0, 4))
        #expect(quoted == "> a\n>\n> b")
        let (plain, _) = try #require(run(.toggleQuote, "> a\n> b", 0, 7))
        #expect(plain == "a\nb")
    }

    @Test func bulletListConvertsAndRemoves() throws {
        let (list, selection) = try #require(run(.toggleBulletList, "one\ntwo", 0, 7))
        #expect(list == "- one\n- two")
        #expect(selection == Selection(anchor: 2, head: 11))

        #expect(try #require(run(.toggleBulletList, "- one\n- two", 0, 11)).0 == "one\ntwo")
        #expect(try #require(run(.toggleBulletList, "1. one\n2. two", 0, 13)).0 == "- one\n- two")
    }

    @Test func selectionEndingAtNextLineStartExcludesThatLine() throws {
        let (text, _) = try #require(run(.toggleBulletList, "one\ntwo\n", 0, 4))
        #expect(text == "- one\ntwo\n")
    }

    @Test func numberedListNumbersSequentially() throws {
        let (text, _) = try #require(run(.toggleNumberedList, "a\nb\nc", 0, 5))
        #expect(text == "1. a\n2. b\n3. c")
    }

    @Test func taskListConvertsBulletsAndRemoves() throws {
        #expect(try #require(run(.toggleTaskList, "- todo", 6)).0 == "- [ ] todo")
        #expect(try #require(run(.toggleTaskList, "todo", 4)).0 == "- [ ] todo")
        #expect(try #require(run(.toggleTaskList, "- [x] done", 10)).0 == "done")
    }

    @Test func listTogglePreservesIndentation() throws {
        #expect(try #require(run(.toggleBulletList, "    nested", 10)).0 == "    - nested")
    }

    @Test func indentAndOutdent() throws {
        #expect(try #require(run(.indent, "- a\n- b", 0, 7)).0 == "    - a\n    - b")
        #expect(try #require(run(.outdent, "    - a\n  - b", 0, 13)).0 == "- a\n- b")
        #expect(run(.outdent, "- a", 0) == nil)
    }

    // MARK: Insertions

    @Test func insertLinkVariants() throws {
        let (empty, cursor) = try #require(run(.insertLink(destination: nil), "", 0))
        #expect(empty == "[]()")
        #expect(cursor == Selection(cursor: 1))

        let (withText, textCursor) = try #require(run(.insertLink(destination: nil), "LiteMD", 0, 6))
        #expect(withText == "[LiteMD]()")
        #expect(textCursor == Selection(cursor: 9))

        let (fromURL, _) = try #require(run(.insertLink(destination: nil), "https://litemd.app", 0, 18))
        #expect(fromURL == "[](https://litemd.app)")
    }

    @Test func insertImageEscapesPathsWithSpaces() throws {
        #expect(try #require(run(.insertImage(path: "assets/image-001.png", alt: ""), "", 0)).0 == "![](assets/image-001.png)")
        #expect(try #require(run(.insertImage(path: "assets/my image.png", alt: "x"), "", 0)).0 == "![x](<assets/my image.png>)")
    }

    @Test func insertCodeBlock() throws {
        let (onEmptyLine, cursor) = try #require(run(.insertCodeBlock(language: "swift"), "", 0))
        #expect(onEmptyLine == "```swift\n\n```")
        #expect(cursor == Selection(cursor: 9))

        let (wrapped, _) = try #require(run(.insertCodeBlock(language: nil), "let a = 1\nlet b = 2", 0, 19))
        #expect(wrapped == "```\nlet a = 1\nlet b = 2\n```")
    }

    @Test func insertTableSelectsFirstHeader() throws {
        let (text, selection) = try #require(run(.insertTable(rows: 1, columns: 2), "", 0))
        #expect(text == "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |")
        #expect(selection == Selection(anchor: 2, head: 10))
    }

    @Test func insertHorizontalRule() throws {
        #expect(try #require(run(.insertHorizontalRule, "", 0)).0 == "---\n")
        #expect(try #require(run(.insertHorizontalRule, "text", 2)).0 == "text\n\n---\n")
    }

    // MARK: Newline

    @Test func newlineContinuesLists() throws {
        let (bullet, cursor) = try #require(run(.insertNewline, "- one", 5))
        #expect(bullet == "- one\n- ")
        #expect(cursor == Selection(cursor: 8))

        #expect(try #require(run(.insertNewline, "9. nine", 7)).0 == "9. nine\n10. ")
        #expect(try #require(run(.insertNewline, "- [x] done", 10)).0 == "- [x] done\n- [ ] ")
        #expect(try #require(run(.insertNewline, "> quote", 7)).0 == "> quote\n> ")
    }

    @Test func newlineOnEmptyItemEndsOrOutdentsList() throws {
        let (ended, cursor) = try #require(run(.insertNewline, "- one\n- ", 8))
        #expect(ended == "- one\n")
        #expect(cursor == Selection(cursor: 6))

        #expect(try #require(run(.insertNewline, "- one\n    - ", 12)).0 == "- one\n- ")
    }

    @Test func newlineInMiddleOfItemSplitsIt() throws {
        #expect(try #require(run(.insertNewline, "- onetwo", 5)).0 == "- one\n- two")
    }

    @Test func newlineFallsBackToPlatformOutsideLists() {
        #expect(run(.insertNewline, "plain", 5) == nil)
        #expect(run(.insertNewline, "```\n- item", 10) == nil)
    }

    @Test func listContinuationCanBeDisabled() {
        let engine = EditorEngine(listContinuation: false)
        #expect(engine.perform(.insertNewline, text: "- one", selection: Selection(cursor: 5)) == nil)
    }
}

@Suite("TextBuffer")
@MainActor
struct TextBufferTests {
    @Test func revisionIncrementsOnEveryEffectiveEdit() {
        let buffer = StringTextBuffer("LiteMD")
        #expect(buffer.revision == 0)
        buffer.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        #expect(buffer.revision == 1)
        buffer.replaceCharacters(in: NSRange(location: 0, length: 0), with: "")
        #expect(buffer.revision == 1)
        buffer.replaceAll(with: "x")
        #expect(buffer.revision == 2)
        #expect(buffer.snapshot() == "x")
    }

    @Test func rangesUseUTF16Units() {
        let buffer = StringTextBuffer("😀中")
        #expect(buffer.length == 3)
        buffer.replaceCharacters(in: NSRange(location: 2, length: 1), with: "文")
        #expect(buffer.snapshot() == "😀文")
    }
}

@Suite("Context menu helpers")
struct ContextMenuHelperTests {
    @Test func toggleTaskCompletionChecksThenUnchecks() throws {
        let engine = EditorEngine()
        let text = "- [ ] a\n- [x] b\nplain"
        let checked = try #require(engine.perform(.toggleTaskCompletion, text: text, selection: Selection(anchor: 0, head: 20)))
        #expect(checked.applied(to: text) == "- [x] a\n- [x] b\nplain")
        #expect(checked.selection == Selection(anchor: 0, head: 20))

        let unchecked = try #require(engine.perform(.toggleTaskCompletion, text: "- [X] done", selection: Selection(cursor: 3)))
        #expect(unchecked.applied(to: "- [X] done") == "- [ ] done")
        #expect(engine.perform(.toggleTaskCompletion, text: "- item", selection: Selection(cursor: 2)) == nil)
    }

    @Test func locatesLinksImagesAndURLs() throws {
        let text = "intro\nSee [Project](Ideas/Project.md) and ![logo](<assets/my logo.png> \"Title\") at https://litemd.app."
        let string = text as NSString

        let link = try #require(MarkdownLinkLocator.link(at: string.range(of: "Project]").location, in: text))
        #expect(link.kind == .link)
        #expect(link.destination == "Ideas/Project.md")
        #expect(string.substring(with: link.range) == "[Project](Ideas/Project.md)")

        let image = try #require(MarkdownLinkLocator.link(at: string.range(of: "my logo").location, in: text))
        #expect(image.kind == .image)
        #expect(image.destination == "assets/my logo.png")

        let url = try #require(MarkdownLinkLocator.link(at: string.range(of: "litemd.app").location, in: text))
        #expect(url.kind == .bareURL)
        #expect(url.destination == "https://litemd.app")

        #expect(MarkdownLinkLocator.link(at: 2, in: text) == nil)
        #expect(MarkdownLinkLocator.link(at: string.range(of: " and ").location + 1, in: text) == nil)
    }
}
