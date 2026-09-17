import Foundation
@testable import LiteMDConversion
import Testing

/// 1×1 红色 PNG。
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

private final class TemporaryFolder {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMDConversion-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("ZIP")
struct ZipTests {
    @Test func roundTripsStoredAndDeflatedEntries() throws {
        var writer = ZipWriter()
        let large = String(repeating: "LiteMD 中文 ", count: 500)
        writer.add("mimetype", string: "application/epub+zip", compress: false)
        writer.add("folder/large.txt", string: large)
        writer.add("binary.png", data: tinyPNG, compress: false)
        let archive = try ZipArchive(data: writer.finish())

        #expect(archive.orderedPaths == ["mimetype", "folder/large.txt", "binary.png"])
        #expect(try archive.string(for: "mimetype") == "application/epub+zip")
        #expect(try archive.string(for: "folder/large.txt") == large)
        #expect(try archive.data(for: "/binary.png") == tinyPNG)
        #expect(ZipArchive.resolve("../media/a.png", relativeTo: "word/document.xml") == "media/a.png")
        #expect(ZipArchive.resolve("media/a.png", relativeTo: "word/document.xml") == "word/media/a.png")
    }

    @Test func rejectsNonArchives() {
        #expect(throws: ConversionError.self) {
            try ZipArchive(data: Data("not a zip".utf8))
        }
    }
}

@Suite("DOCX")
struct DocxTests {
    let markdown = """
    # 项目计划

    Some **bold**, *italic*, ~~old~~ and `code` with a [link](https://litemd.app).

    ## Tasks

    - First
    - Second
        - Nested

    1. One
    2. Two

    - [x] Done
    - [ ] Todo

    > Quote line

    ```swift
    let value = 1
    print(value)
    ```

    | Name | Value |
    | :--- | ---: |
    | LiteMD | 中文 |

    ![Logo](logo.png)
    """

    @Test func exportsWellFormedPackage() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))

        let data = try DocxExporter().export(markdown, options: ExportOptions(title: "Plan", documentDirectory: folder.url))
        let archive = try ZipArchive(data: data)

        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
            let xml = try archive.data(for: part)
            #expect(throws: Never.self) { try XMLTree.parse(xml) }
        }
        #expect(archive.contains("word/media/image1.png"))

        let document = try archive.string(for: "word/document.xml")
        #expect(document.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(document.contains("<w:numPr><w:ilvl w:val=\"1\"/>"))
        #expect(document.contains("<w:rStyle w:val=\"VerbatimChar\"/>"))
        #expect(document.contains("<w:hyperlink r:id="))
        #expect(document.contains("<w:tbl>"))
    }

    @Test func roundTripsThroughImporter() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))
        let data = try DocxExporter().export(markdown, options: ExportOptions(title: "Plan", documentDirectory: folder.url))

        let result = try DocxImporter().convert(data, options: ImportOptions(assetDirectory: "assets", assetPrefix: "plan"))
        let output = result.markdown
        #expect(output.contains("# 项目计划"))
        #expect(output.contains("## Tasks"))
        #expect(output.contains("**bold**"))
        #expect(output.contains("*italic*"))
        #expect(output.contains("~~old~~"))
        #expect(output.contains("`code`"))
        #expect(output.contains("[link](https://litemd.app)"))
        #expect(output.contains("- First\n- Second\n    - Nested"))
        #expect(output.contains("- Nested\n\n1. One\n1. Two"))
        #expect(output.contains("- [x] Done\n- [ ] Todo"))
        #expect(output.contains("> Quote line"))
        #expect(output.contains("```\nlet value = 1\nprint(value)\n```"))
        #expect(output.contains("| Name | Value |"))
        #expect(output.contains("| LiteMD | 中文 |"))
        #expect(output.contains("![Logo](assets/plan-1.png)"))
        #expect(result.assets == [ConvertedAsset(fileName: "plan-1.png", data: tinyPNG)])
        #expect(result.title == "Plan")
    }

    @Test func importsPandocGeneratedDocument() throws {
        let url = try #require(Bundle.module.url(forResource: "pandoc-sample", withExtension: "docx", subdirectory: "Fixtures"))
        let result = try DocxImporter().convert(try Data(contentsOf: url))
        #expect(result.markdown.contains("# LiteMD"))
        #expect(result.markdown.contains("## Features"))
        #expect(result.markdown.contains("**Local-first**"))
        #expect(result.markdown.contains("| Name | Value |"))
        #expect(result.markdown.contains("> Markdown File = Source of Truth"))
        #expect(result.assets.count == 1)
    }
}

@Suite("Office importers")
struct OfficeImporterTests {
    @Test func importsSpreadsheetSheetsAsTables() throws {
        var writer = ZipWriter()
        writer.add("xl/workbook.xml", string: """
        <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="预算" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        writer.add("xl/_rels/workbook.xml.rels", string: """
        <Relationships><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        writer.add("xl/sharedStrings.xml", string: "<sst><si><t>Item</t></si><si><t>Cost</t></si><si><r><t>Coffee</t></r><r><t> beans</t></r></si></sst>")
        writer.add("xl/worksheets/sheet1.xml", string: """
        <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>12.5</v></c></row></sheetData></worksheet>
        """)

        let result = try XlsxImporter().convert(writer.finish())
        #expect(result.markdown == "## 预算\n\n| Item | Cost |  |\n| --- | --- | --- |\n| Coffee beans |  | 12.5 |\n")
        #expect(XlsxImporter.columnIndex("AB12") == 27)
    }

    @Test func importsSlidesWithTitlesBulletsAndNotes() throws {
        var writer = ZipWriter()
        writer.add("ppt/presentation.xml", string: """
        <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst></p:presentation>
        """)
        writer.add("ppt/_rels/presentation.xml.rels", string: "<Relationships><Relationship Id=\"rId2\" Type=\"slide\" Target=\"slides/slide1.xml\"/></Relationships>")
        writer.add("ppt/slides/slide1.xml", string: """
        <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Roadmap</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody>
        <a:p><a:r><a:rPr b="1"/><a:t>Native</a:t></a:r><a:r><a:t> apps</a:t></a:r></a:p>
        <a:p><a:pPr lvl="1"/><a:r><a:t>macOS first</a:t></a:r></a:p>
        </p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        writer.add("ppt/slides/_rels/slide1.xml.rels", string: "<Relationships><Relationship Id=\"rId9\" Type=\"http://x/notesSlide\" Target=\"../notesSlides/notesSlide1.xml\"/></Relationships>")
        writer.add("ppt/notesSlides/notesSlide1.xml", string: """
        <p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Mention iOS</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>
        """)

        let result = try PptxImporter().convert(writer.finish())
        #expect(result.markdown == "## Roadmap\n\n- **Native** apps\n    - macOS first\n\n> Mention iOS\n")
    }
}

@Suite("HTML, EPUB, CSV, LaTeX")
struct WebAndTextConversionTests {
    @Test func convertsMessyHTML() throws {
        let html = """
        <html><head><title>Notes</title><script>alert(1)</script></head>
        <body><h1>Hello &amp; welcome</h1>
        <p>Some <b>bold</b> and <a href="https://litemd.app">a link</a><br>next line
        <p>Second paragraph with <code>x < y</code>
        <ul><li>One<li>Two <em>em</em></ul>
        <table><tr><th>A<th>B</tr><tr><td>1<td>2</tr></table>
        <pre><code class="language-swift">let a = 1</code></pre>
        <img src="pic.png" alt="Pic">
        </body></html>
        """
        let result = try DocumentImporter().convert(Data(html.utf8), fileName: "page.html", options: ImportOptions())
        #expect(result.title == "Notes")
        #expect(result.markdown.contains("# Hello & welcome"))
        #expect(result.markdown.contains("Some **bold** and [a link](https://litemd.app)<br>next line"))
        #expect(result.markdown.contains("Second paragraph with `x < y`"))
        #expect(result.markdown.contains("- One\n- Two *em*"))
        #expect(result.markdown.contains("| A | B |"))
        #expect(result.markdown.contains("```swift\nlet a = 1\n```"))
        #expect(result.markdown.contains("![Pic](pic.png)"))
        #expect(!result.markdown.contains("alert"))
    }

    @Test func epubRoundTripKeepsStructureAndImages() throws {
        let folder = TemporaryFolder()
        try tinyPNG.write(to: folder.url.appendingPathComponent("logo.png"))
        let markdown = "# Book\n\nIntro **text**.\n\n## Chapter\n\n- item\n\n![Logo](logo.png)\n\n<div>raw</div>\n"

        let data = try EpubExporter().export(markdown, options: ExportOptions(title: "My Book", documentDirectory: folder.url, language: "zh-Hans"), stylesheet: "body{}")
        let archive = try ZipArchive(data: data)
        #expect(archive.orderedPaths.first == "mimetype")
        for part in ["OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml", "META-INF/container.xml"] {
            #expect(throws: Never.self) { try XMLTree.parse(try archive.data(for: part)) }
        }

        let result = try EpubImporter().convert(data, options: ImportOptions(assetPrefix: "book"))
        #expect(result.title == "My Book")
        #expect(result.markdown.contains("## Chapter"))
        #expect(result.markdown.contains("Intro **text**."))
        #expect(result.markdown.contains("![Logo](assets/book-1.png)"))
        #expect(result.assets.count == 1)
    }

    @Test func csvHandlesQuotesAndDelimiters() throws {
        let csv = "name,note\n\"LiteMD, app\",\"say \"\"hi\"\"\"\nplain,\"multi\nline\"\n"
        let result = try CsvImporter().convert(csv)
        #expect(result.markdown == "| name | note |\n| --- | --- |\n| LiteMD, app | say \"hi\" |\n| plain | multi<br>line |\n")
        #expect(CsvImporter.detectDelimiter("a;b;c\n1;2;3") == ";")
    }

    @Test func latexEscapesAndUsesCtexForChinese() {
        let latex = LatexExporter().export("# 标题\n\n100% of $5 & **bold** `a_b`\n\n- [x] done\n", options: ExportOptions(title: "T_1"))
        #expect(latex.contains("\\documentclass[11pt]{ctexart}"))
        #expect(latex.contains("\\section{标题}"))
        #expect(latex.contains("100\\% of \\$5 \\& \\textbf{bold} \\texttt{a\\_b}"))
        #expect(latex.contains("\\item[$\\boxtimes$] done"))
        #expect(latex.contains("\\title{T\\_1}"))
    }
}
