import AppKit
import LiteMDMarkdown

/// 实时预览中整行的装饰：代码块底色、引用竖线、分隔线、图片。
/// 作为文本属性挂在行上，由 `LiveLayoutFragment` 绘制；正文字符本身不变。
final class LiveDecoration: NSObject, @unchecked Sendable {
    enum Kind {
        case codeBlock
        case quote
        case rule
        case image
    }

    let kind: Kind
    let image: NSImage?
    let imageSize: CGSize

    init(kind: Kind, image: NSImage? = nil, imageSize: CGSize = .zero) {
        self.kind = kind
        self.image = image
        self.imageSize = imageSize
    }
}

extension NSAttributedString.Key {
    static let liveDecoration = NSAttributedString.Key("LiteMDLiveDecoration")
}

/// 为带装饰的段落提供自定义布局片段。只读取文本属性，不访问编辑器状态。
final class LiveLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(.liveDecoration, at: 0, effectiveRange: nil) as? LiveDecoration {
            return LiveLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

final class LiveLayoutFragment: NSTextLayoutFragment {
    private let decoration: LiveDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: LiveDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 文本区域（相对片段原点）：从行首内边距到容器宽度。片段自身的宽度只等于文字宽度，隐藏标记后可能接近 0。
    private var contentRect: CGRect {
        let container = textLayoutManager?.textContainer
        let padding = container?.lineFragmentPadding ?? 0
        let width = (container?.size.width ?? layoutFragmentFrame.width) - padding * 2
        return CGRect(x: padding - layoutFragmentFrame.minX, y: 0, width: max(width, layoutFragmentFrame.width), height: layoutFragmentFrame.height)
    }

    private var textMaxY: CGFloat {
        textLineFragments.map(\.typographicBounds.maxY).max() ?? layoutFragmentFrame.height
    }

    private var imageRect: CGRect {
        CGRect(x: contentRect.minX, y: textMaxY + Space.s2, width: decoration.imageSize.width, height: decoration.imageSize.height)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        switch decoration.kind {
        case .image:
            bounds = bounds.union(imageRect)
        case .codeBlock, .rule, .quote:
            bounds = bounds.union(contentRect.insetBy(dx: -Space.s2, dy: 0))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let frame = contentRect.offsetBy(dx: point.x, dy: point.y)
        switch decoration.kind {
        case .codeBlock:
            Palette.surfaceMuted.setFill()
            frame.insetBy(dx: -Space.s2, dy: 0).fill()
            super.draw(at: point, in: context)
        case .quote:
            super.draw(at: point, in: context)
            Palette.border.setFill()
            CGRect(x: frame.minX, y: frame.minY, width: Space.s1 - 1, height: frame.height).fill()
        case .rule:
            super.draw(at: point, in: context)
            Palette.border.setFill()
            CGRect(x: frame.minX, y: frame.midY.rounded(), width: frame.width, height: 1).fill()
        case .image:
            super.draw(at: point, in: context)
            if let image = decoration.image {
                let rect = imageRect.offsetBy(dx: point.x, dy: point.y)
                let path = NSBezierPath(roundedRect: rect, xRadius: Radius.small, yRadius: Radius.small)
                path.addClip()
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
        }
    }
}

/// 实时预览的图片缓存。读取在后台进行，完成后回调重新着色对应段落。
@MainActor
final class LiveImageCache {
    static let shared = LiveImageCache()

    private var images: [URL: (image: NSImage, modified: Date?)] = [:]
    private var loading: Set<URL> = []

    func image(for url: URL, onLoad: @escaping @MainActor () -> Void) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = images[url], cached.modified == modified { return cached.image }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        Task {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            self.loading.remove(url)
            guard let data, let image = NSImage(data: data) else { return }
            self.images[url] = (image, modified)
            onLoad()
        }
        return nil
    }

    /// 按可用宽度缩放，不放大，最高 320pt。
    static func displaySize(for image: NSImage, maximumWidth: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let maximumHeight = Space.s16 * 5
        let scale = min(1, maximumWidth / size.width, maximumHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

extension SyntaxStyler {
    /// 实时预览中隐藏的语法标记：字号趋近 0 且透明，仍占据正文字符位置。
    var hiddenAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
    }

    func liveHeadingFont(level: Int) -> NSFont {
        let scale: CGFloat = switch level {
        case 1: 1.75
        case 2: 1.5
        case 3: 1.25
        case 4: 1.125
        default: 1
        }
        return NSFontManager.shared.convert(headingFont, toSize: (baseFont.pointSize * scale).rounded())
    }
}
