import AppKit
import LiteMDDomain
import LiteMDEditor
import LiteMDMarkdown

/// 以闭包执行的菜单项。
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        _ title: String.LocalizationValue,
        symbol: String? = nil,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: String(localized: title), action: #selector(invoke), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        self.isEnabled = isEnabled
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func invoke() {
        handler()
    }
}

extension NSMenu {
    /// 去掉开头、结尾与连续的分隔线。
    func normalizeSeparators() {
        var previousWasSeparator = true
        for item in items {
            if item.isSeparatorItem {
                if previousWasSeparator { removeItem(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        while let last = items.last, last.isSeparatorItem {
            removeItem(last)
        }
    }

    func addSubmenu(_ title: String.LocalizationValue, symbol: String? = nil, items: [NSMenuItem]) {
        let localized = String(localized: title)
        let submenu = NSMenu(title: localized)
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: localized, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        item.submenu = submenu
        addItem(item)
    }
}

/// 编辑器右键菜单。
///
/// 结构：上下文操作（链接 / 图片 / 任务）→ 剪切拷贝粘贴与“复制为”→ 格式 / 段落 / 插入
/// → 以选中内容新建文档、在文件夹中搜索 → 共享 → 系统提供的写作工具、拼写、语音、服务、连续互通相机等。
@MainActor
struct EditorContextMenuBuilder {
    let controller: EditorController
    let model: AppModel
    let systemMenu: NSMenu
    let characterIndex: Int

    private var textView: MarkdownTextView { controller.textView }
    private var document: Document { controller.document }

    func build() -> NSMenu {
        let menu = NSMenu(title: systemMenu.title)
        let text = document.text
        let selection = textView.selectedRange()
        let selectedText = selection.length > 0 ? (text as NSString).substring(with: selection) : ""

        addContextItems(to: menu, text: text)
        menu.addItem(.separator())

        addEditingItems(to: menu, selectedText: selectedText, fullText: text)
        menu.addItem(.separator())

        addMarkdownItems(to: menu)
        menu.addItem(.separator())

        addDocumentItems(to: menu, selectedText: selectedText)
        menu.addItem(.separator())

        addRemainingSystemItems(to: menu, selectedText: selectedText)
        menu.normalizeSeparators()
        return menu
    }

    // MARK: Context

    private func addContextItems(to menu: NSMenu, text: String) {
        if let wikiLink = MarkdownExtensionScanner.wikiLinks(in: text).first(where: { NSLocationInRange(characterIndex, $0.range) }) {
            let title = wikiLink.target.isEmpty ? (wikiLink.anchor ?? "") : wikiLink.target
            menu.addItem(ActionMenuItem("Open “\(title)”", symbol: "link") {
                model.openWikiLink(target: wikiLink.target, anchor: wikiLink.anchor, from: document)
            })
            menu.addItem(ActionMenuItem("Copy Link Target", symbol: "doc.on.clipboard") {
                SystemIntegration.copyToPasteboard(wikiLink.target)
            })
            return
        }
        if let link = MarkdownLinkLocator.link(at: characterIndex, in: text) {
            switch link.kind {
            case .image:
                let fileURL = model.resolveLocalURL(link.destination, relativeTo: document)
                menu.addItem(ActionMenuItem("Open Image", symbol: "photo") {
                    model.openLinkDestination(link.destination, relativeTo: document)
                })
                if let fileURL {
                    menu.addItem(ActionMenuItem("Reveal Image in Finder", symbol: "folder") {
                        SystemIntegration.revealInFinder(fileURL)
                    })
                }
                menu.addItem(ActionMenuItem("Copy Image Path", symbol: "doc.on.clipboard") {
                    SystemIntegration.copyToPasteboard(fileURL?.path ?? link.destination)
                })
            case .link, .autolink, .bareURL:
                menu.addItem(ActionMenuItem("Open Link", symbol: "arrow.up.right.square") {
                    model.openLinkDestination(link.destination, relativeTo: document)
                })
                menu.addItem(ActionMenuItem("Copy Link Address", symbol: "link") {
                    SystemIntegration.copyToPasteboard(link.destination)
                })
                if link.kind == .link {
                    menu.addItem(ActionMenuItem("Edit Link Address") {
                        selectLinkDestination(link)
                    })
                    menu.addItem(ActionMenuItem("Remove Link") {
                        let edit = TextEdit(range: link.range, replacement: link.text)
                        let end = link.range.location + link.text.utf16.count
                        controller.apply(EditResult(edit: edit, selection: Selection(anchor: link.range.location, head: end)), actionName: String(localized: "Remove Link"))
                    })
                }
            }
        }

        if let task = taskState(at: characterIndex, in: text) {
            menu.addItem(ActionMenuItem(task == .checked ? "Mark as Not Done" : "Mark as Done", symbol: task == .checked ? "circle" : "checkmark.circle") {
                moveCaretIfOutsideSelection()
                controller.perform(.toggleTaskCompletion)
            })
        }
    }

    private func taskState(at index: Int, in text: String) -> MarkdownLineSyntax.TaskState? {
        let string = text as NSString
        guard index <= string.length else { return nil }
        let lineRange = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
        let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
        return MarkdownLineSyntax.parseListPrefix(line)?.task
    }

    private func selectLinkDestination(_ link: LocatedLink) {
        let source = (document.text as NSString).substring(with: link.range) as NSString
        let separator = source.range(of: "](")
        guard separator.location != NSNotFound else { return }
        let start = link.range.location + separator.location + 2
        let length = link.range.length - separator.location - 3
        textView.setSelectedRange(NSRange(location: start, length: max(0, length)))
        controller.focus()
    }

    private func moveCaretIfOutsideSelection() {
        let selection = textView.selectedRange()
        if !NSLocationInRange(characterIndex, selection), characterIndex != NSMaxRange(selection) {
            textView.setSelectedRange(NSRange(location: characterIndex, length: 0))
        }
    }

    // MARK: Editing

    private func takeSystemItem(_ action: Selector) -> NSMenuItem? {
        guard let item = systemMenu.items.first(where: { $0.action == action }) else { return nil }
        systemMenu.removeItem(item)
        return item
    }

    private func addEditingItems(to menu: NSMenu, selectedText: String, fullText: String) {
        menu.addItem(takeSystemItem(#selector(NSText.cut(_:))) ?? NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        menu.addItem(takeSystemItem(#selector(NSText.copy(_:))) ?? NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        menu.addItem(takeSystemItem(#selector(NSText.paste(_:))) ?? NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: ""))

        let source = selectedText.isEmpty ? fullText : selectedText
        let wholeDocument = selectedText.isEmpty
        menu.addSubmenu("Copy As", symbol: "doc.on.doc", items: [
            ActionMenuItem(wholeDocument ? "Markdown (Entire Document)" : "Markdown") {
                SystemIntegration.copyToPasteboard(source)
            },
            ActionMenuItem(wholeDocument ? "Plain Text (Entire Document)" : "Plain Text") {
                SystemIntegration.copyToPasteboard(MarkdownParser().plainText(from: source))
            },
            ActionMenuItem(wholeDocument ? "HTML (Entire Document)" : "HTML") {
                let html = MarkdownParser().htmlFragment(from: source)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(html, forType: .html)
                pasteboard.setString(html, forType: .string)
            },
        ])

        _ = takeSystemItem(#selector(NSTextView.pasteAsPlainText(_:)))
        let pasteSpecial = NSMenuItem(title: String(localized: "Paste as Plain Text"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteSpecial.keyEquivalentModifierMask = [.command, .option, .shift]
        pasteSpecial.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(pasteSpecial)
    }

    // MARK: Markdown

    private func command(_ title: String.LocalizationValue, _ command: EditorCommand, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> ActionMenuItem {
        ActionMenuItem(title, key: key, modifiers: modifiers) {
            controller.perform(command)
        }
    }

    private func addMarkdownItems(to menu: NSMenu) {
        menu.addSubmenu("Format", symbol: "bold.italic.underline", items: [
            command("Bold", .toggleBold, key: "b"),
            command("Italic", .toggleItalic, key: "i"),
            command("Strikethrough", .toggleStrikethrough, key: "x", modifiers: [.command, .shift]),
            command("Inline Code", .toggleInlineCode, key: "`", modifiers: [.control]),
            command("Highlight", .toggleHighlight, key: "h", modifiers: [.command, .shift]),
            .separator(),
            command("Link", .insertLink(destination: nil), key: "k"),
        ])

        var paragraphItems: [NSMenuItem] = (1...6).map { level in
            command("Heading \(level)", .setHeading(level: level), key: "\(level)")
        }
        paragraphItems.append(command("Body Text", .setHeading(level: 0), key: "0"))
        paragraphItems.append(.separator())
        paragraphItems.append(command("Quote", .toggleQuote, key: "'", modifiers: [.command, .option]))
        paragraphItems.append(command("Bulleted List", .toggleBulletList, key: "u", modifiers: [.command, .option]))
        paragraphItems.append(command("Numbered List", .toggleNumberedList, key: "o", modifiers: [.command, .option]))
        paragraphItems.append(command("Task List", .toggleTaskList, key: "x", modifiers: [.command, .option]))
        paragraphItems.append(.separator())
        paragraphItems.append(command("Indent", .indent, key: "]"))
        paragraphItems.append(command("Outdent", .outdent, key: "["))
        menu.addSubmenu("Paragraph", symbol: "text.alignleft", items: paragraphItems)

        menu.addSubmenu("Insert", symbol: "plus.square", items: [
            ActionMenuItem("Image…", key: "i", modifiers: [.command, .control]) {
                model.insertImageFromPanel()
            },
            command("Table", .insertTable(rows: 2, columns: 2), key: "t", modifiers: [.command, .control]),
            command("Code Block", .insertCodeBlock(language: nil), key: "c", modifiers: [.command, .option]),
            command("Horizontal Rule", .insertHorizontalRule, key: "-", modifiers: [.command, .option]),
        ])
    }

    // MARK: Document

    private func addDocumentItems(to menu: NSMenu, selectedText: String) {
        let hasSelection = !selectedText.isEmpty
        menu.addItem(ActionMenuItem("New Document with Selection", symbol: "doc.badge.plus", isEnabled: hasSelection) {
            model.newDocument(text: selectedText)
        })

        let query = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, !query.contains("\n"), query.count <= 60 {
            let preview = query.count > 24 ? String(query.prefix(24)) + "…" : query
            menu.addItem(ActionMenuItem("Search in Folder for “\(preview)”", symbol: "magnifyingglass") {
                model.searchInFolder(query)
            })
        }
    }

    // MARK: System

    private func addRemainingSystemItems(to menu: NSMenu, selectedText: String) {
        let items = systemMenu.items
        systemMenu.removeAllItems()

        let hasShareItem = items.contains { item in
            let title = item.title.lowercased()
            return title.hasPrefix("share") || item.title.hasPrefix("共享")
        }
        if !hasShareItem {
            var shareItems: [Any] = []
            if !selectedText.isEmpty {
                shareItems.append(selectedText)
            } else if let url = document.fileReference?.url {
                shareItems.append(url)
            } else {
                shareItems.append(document.text)
            }
            let picker = NSSharingServicePicker(items: shareItems)
            // 菜单项不持有 picker，需要由控制器保留到菜单关闭之后。
            controller.retainedSharingPicker = picker
            menu.addItem(picker.standardShareMenuItem)
            menu.addItem(.separator())
        }

        for item in items where !Self.isUnwanted(item) {
            menu.addItem(item)
        }
    }

    /// 与 Markdown 源码编辑冲突或无意义的系统菜单：字体、智能替换（会破坏 Markdown 语法）、文字方向。
    static func isUnwanted(_ item: NSMenuItem) -> Bool {
        let unwantedActions: Set<Selector> = [
            #selector(NSFontManager.orderFrontFontPanel(_:)),
            #selector(NSTextView.changeLayoutOrientation(_:)),
            #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
        ]
        if let action = item.action, unwantedActions.contains(action) { return true }
        guard let submenu = item.submenu else { return false }
        let actions = Set(submenu.items.compactMap(\.action))
        return actions.contains(#selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
            || actions.contains(#selector(NSFontManager.orderFrontFontPanel(_:)))
            || actions.contains(#selector(NSTextView.changeLayoutOrientation(_:)))
    }
}
