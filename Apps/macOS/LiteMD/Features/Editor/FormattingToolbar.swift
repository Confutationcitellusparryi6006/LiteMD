import LiteMDEditor
import SwiftUI

/// 悬浮在编辑区底部的格式工具栏。与菜单、快捷键、右键菜单发出同一组 EditorCommand。
struct FormattingToolbar: View {
    @Environment(AppModel.self) private var model

    /// 工具栏占用的高度（含底部留白），编辑区据此增加底部内边距，最后几行不会被遮挡。
    static let reservedHeight: CGFloat = Space.s16

    var body: some View {
        // 编辑区较窄时使用紧凑版，避免工具栏被截断。
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
        .padding(.horizontal, Space.s2)
        .padding(.bottom, Space.s4)
    }

    private var compactBar: some View {
        HStack(spacing: Space.s1) {
            headingMenu
            ToolbarIconButton(symbol: "bold", help: "Bold") { run(.toggleBold) }
            ToolbarIconButton(symbol: "italic", help: "Italic") { run(.toggleItalic) }
            ToolbarIconButton(symbol: "link", help: "Link") { run(.insertLink(destination: nil)) }
            moreMenu(includesAll: true)
        }
        .toolbarCapsule()
    }

    private var headingMenu: some View {
        ToolbarMenu(help: "Heading") {
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { run(.setHeading(level: level)) }
            }
            Divider()
            Button("Body Text") { run(.setHeading(level: 0)) }
        } label: {
            Text(verbatim: "H")
                .font(.system(size: IconSize.standalone, weight: .bold))
        }
    }

    private func moreMenu(includesAll: Bool) -> some View {
        ToolbarMenu(help: "More", showsChevron: false) {
            if includesAll {
                Button("Task List") { run(.toggleTaskList) }
                Button("Bulleted List") { run(.toggleBulletList) }
                Button("Numbered List") { run(.toggleNumberedList) }
                Button("Highlight") { run(.toggleHighlight) }
                Button("Table") { run(.insertTable(rows: 2, columns: 2)) }
                Button("Image…") { model.insertImageFromPanel() }
                Button("Start Dictation") { model.startDictation() }
                Divider()
            }
            Button("Quote") { run(.toggleQuote) }
            Button("Code Block") { run(.insertCodeBlock(language: nil)) }
            Button("Horizontal Rule") { run(.insertHorizontalRule) }
            Divider()
            Button("Strikethrough") { run(.toggleStrikethrough) }
            Button("Inline Code") { run(.toggleInlineCode) }
            Divider()
            Button("Hide Toolbar") { model.settings.showFormattingToolbar = false }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
        }
    }

    private var fullBar: some View {
        HStack(spacing: Space.s1) {
            headingMenu

            ToolbarIconButton(symbol: "checkmark.square", help: "Task List") {
                run(.toggleTaskList)
            }

            ToolbarMenu(help: "Lists") {
                Button("Bulleted List") { run(.toggleBulletList) }
                Button("Numbered List") { run(.toggleNumberedList) }
                Button("Task List") { run(.toggleTaskList) }
                Divider()
                Button("Indent") { run(.indent) }
                Button("Outdent") { run(.outdent) }
            } label: {
                Image(systemName: "list.bullet")
            }

            ToolbarSpacer()

            ToolbarIconButton(symbol: "bold", help: "Bold") { run(.toggleBold) }
            ToolbarIconButton(symbol: "italic", help: "Italic") { run(.toggleItalic) }

            ToolbarMenu(help: "Highlight") {
                Button("Highlight") { run(.toggleHighlight) }
                Button("Strikethrough") { run(.toggleStrikethrough) }
                Button("Inline Code") { run(.toggleInlineCode) }
            } label: {
                Image(systemName: "highlighter")
            }

            ToolbarSpacer()

            ToolbarIconButton(symbol: "link", help: "Link") { run(.insertLink(destination: nil)) }
            ToolbarIconButton(symbol: "tablecells", help: "Table") { run(.insertTable(rows: 2, columns: 2)) }
            ToolbarIconButton(symbol: "photo.on.rectangle", help: "Image") { model.insertImageFromPanel() }
            ToolbarIconButton(symbol: "mic", help: "Start Dictation") { model.startDictation() }

            moreMenu(includesAll: false)
        }
        .toolbarCapsule()
    }

    private func run(_ command: EditorCommand) {
        model.perform(command)
        model.activeEditor?.focus()
    }
}

private extension View {
    func toolbarCapsule() -> some View {
        modifier(ToolbarGlass())
    }
}

/// 悬浮工具栏的背板。
///
/// macOS 26 起用系统的液态玻璃（自带边缘高光与折射，不需要再描边）；
/// 更早的系统退回 vibrancy 材质 + 细描边 + 一层阴影，保持“浮在正文之上”的层次。
private struct ToolbarGlass: ViewModifier {
    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)

        if #available(macOS 26.0, *) {
            padded
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
        } else {
            padded
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: 1))
                .shadow(
                    color: Elevation.level2Color,
                    radius: Elevation.level2Radius,
                    y: Elevation.level2Offset
                )
                .fixedSize()
        }
    }
}

private struct ToolbarSpacer: View {
    var body: some View {
        Color.clear.frame(width: Space.s3, height: Space.s1)
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.inline + Space.s1, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .frame(width: Space.s8, height: Space.s8)
                .background(
                    Capsule()
                        .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolbarMenu<Content: View, Label: View>: View {
    let help: LocalizedStringKey
    var showsChevron = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    init(
        help: LocalizedStringKey,
        showsChevron: Bool = true,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.help = help
        self.showsChevron = showsChevron
        self.content = content
        self.label = label
    }

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: Space.s1 / 2) {
                label()
                    .font(.system(size: IconSize.inline + Space.s1, weight: .medium))
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: TextSize.xs - Space.s1, weight: .bold))
                }
            }
            .foregroundStyle(Color.textPrimary)
            .frame(minWidth: Space.s8, minHeight: Space.s8)
            .padding(.horizontal, showsChevron ? Space.s1 : 0)
            .background(
                Capsule()
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
