import AppKit
import LiteMDMarkdown

/// 高亮 token → 文本属性。只影响显示，绝不修改正文（spec §49）。
/// 编辑器排版参数。任意一项变化都需要重新着色。
struct EditorTypography: Equatable {
    var font: NSFont
    var headingFont: NSFont
    var codeFont: NSFont
    var lineHeight: CGFloat
    /// 段落间距与首行缩进，单位 em。
    var paragraphSpacing: CGFloat
    var paragraphIndent: CGFloat
}

@MainActor
struct SyntaxStyler {
    let typography: EditorTypography
    let base: [NSAttributedString.Key: Any]
    private let styles: [HighlightKind: [NSAttributedString.Key: Any]]

    var baseFont: NSFont { typography.font }
    var codeFont: NSFont { typography.codeFont }
    var headingFont: NSFont { typography.headingFont }

    init(typography: EditorTypography) {
        self.typography = typography
        let font = typography.font
        let size = font.pointSize

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = typography.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = (typography.paragraphSpacing * size).rounded()
        paragraph.firstLineHeadIndent = (typography.paragraphIndent * size).rounded()

        base = [
            .font: font,
            .foregroundColor: Palette.textPrimary,
            .paragraphStyle: paragraph,
        ]

        // 标题、列表、引用、代码等结构化段落不缩进。
        let structural = paragraph.mutableCopy() as! NSMutableParagraphStyle
        structural.firstLineHeadIndent = 0

        let fontManager = NSFontManager.shared
        let bold = fontManager.convert(font, toHaveTrait: .boldFontMask)
        let italic = fontManager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = fontManager.convert(bold, toHaveTrait: .italicFontMask)
        let codeFont = typography.codeFont

        var styles: [HighlightKind: [NSAttributedString.Key: Any]] = [:]
        for kind in [HighlightKind.heading1, .heading2, .heading3, .heading4, .heading5, .heading6] {
            styles[kind] = [.font: typography.headingFont, .foregroundColor: Palette.heading, .paragraphStyle: structural]
        }
        styles[.marker] = [.foregroundColor: Palette.textTertiary]
        styles[.strong] = [.font: bold]
        styles[.emphasis] = [.font: italic]
        styles[.strongEmphasis] = [.font: boldItalic]
        styles[.strikethrough] = [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.textSecondary]
        styles[.highlight] = [.backgroundColor: Palette.highlight]
        styles[.inlineCode] = [.font: codeFont, .foregroundColor: Palette.primary]
        styles[.codeFence] = [.font: codeFont, .foregroundColor: Palette.textTertiary]
        styles[.codeBlock] = [.font: codeFont, .foregroundColor: Palette.textPrimary]
        styles[.link] = [.foregroundColor: Palette.primary]
        styles[.url] = [.foregroundColor: Palette.textSecondary]
        styles[.image] = [.foregroundColor: Palette.primary]
        styles[.quote] = [.foregroundColor: Palette.textSecondary]
        styles[.listMarker] = [.foregroundColor: Palette.primary]
        styles[.taskChecked] = [.foregroundColor: Palette.textSecondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        styles[.horizontalRule] = [.foregroundColor: Palette.textTertiary]
        styles[.table] = [.foregroundColor: Palette.textTertiary]
        styles[.frontMatter] = [.font: codeFont, .foregroundColor: Palette.textSecondary]
        styles[.html] = [.foregroundColor: Palette.textSecondary]
        styles[.wikiLink] = [.foregroundColor: Palette.primary]
        styles[.math] = [.font: codeFont, .foregroundColor: Palette.textSecondary]
        for kind in [HighlightKind.listMarker, .quote, .codeBlock, .codeFence, .table, .horizontalRule, .frontMatter, .taskBox] {
            styles[kind, default: [:]][.paragraphStyle] = structural
        }
        self.styles = styles
    }

    func attributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        styles[kind] ?? [:]
    }
}
