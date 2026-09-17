import AppKit
import LiteMDDomain
import LiteMDInfrastructure
import Observation
import SwiftUI

extension FolderColor {
    /// 浅色 / 深色外观各一组，深色侧栏上同样清晰。
    var nsColor: NSColor {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .red: (0xDC2626, 0xF87171)
        case .orange: (0xEA580C, 0xFB923C)
        case .yellow: (0xCA8A04, 0xFACC15)
        case .green: (0x16A34A, 0x4ADE80)
        case .teal: (0x0D9488, 0x2DD4BF)
        case .blue: (0x2563EB, 0x60A5FA)
        case .purple: (0x9333EA, 0xC084FC)
        case .gray: (0x6B7280, 0x9CA3AF)
        }
        return Palette.dynamic(light: light, dark: dark)
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// 文件夹图标与颜色。保存在应用数据目录（State/folder-appearance.json），重命名、移动时跟随迁移。
@MainActor
@Observable
final class FolderAppearanceModel {
    private(set) var map = FolderAppearanceMap()

    @ObservationIgnored private let store: JSONStateStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false
    private static let key = "folder-appearance"

    init(store: JSONStateStore) {
        self.store = store
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        if let stored = await store.load(FolderAppearanceMap.self, key: Self.key) {
            map = stored
        }
    }

    func appearance(for url: URL) -> FolderAppearance {
        map.appearance(for: url) ?? FolderAppearance()
    }

    func update(_ url: URL, _ change: (inout FolderAppearance) -> Void) {
        var appearance = appearance(for: url)
        change(&appearance)
        map.set(appearance, for: url)
        scheduleSave()
    }

    func reset(_ url: URL) {
        map.set(FolderAppearance(), for: url)
        scheduleSave()
    }

    func itemMoved(from source: URL, to destination: URL) {
        map.itemMoved(from: source, to: destination)
        scheduleSave()
    }

    func itemRemoved(at url: URL) {
        map.itemRemoved(at: url)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let map = map
        let store = store
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await store.save(map, key: Self.key)
        }
    }
}

/// 文件夹图标：自定义图标与颜色，未设置时使用主题强调色的默认文件夹。
struct FolderIcon: View {
    @Environment(\.colorTheme) private var colorTheme
    let appearance: FolderAppearance
    var isExpanded = false

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(appearance.color?.color ?? Color.themeAccent(colorTheme))
    }

    private var symbolName: String {
        guard let symbol = appearance.symbol, symbol != .folder else {
            return isExpanded ? "folder.fill" : "folder"
        }
        return symbol.systemName
    }
}

/// “图标与颜色”面板：一排颜色、6 × 4 图标、名称同色开关与恢复默认。
struct FolderAppearancePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorTheme) private var colorTheme
    let url: URL

    private let columns = Array(repeating: GridItem(.flexible(minimum: Layout.folderSymbolCell), spacing: Space.s2), count: 6)

    var body: some View {
        let appearance = model.folderAppearance.appearance(for: url)
        let tint = appearance.color?.color ?? Color.themeAccent(colorTheme)

        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Icon and Color")
                .font(.system(size: TextSize.sm, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: Space.s2) {
                swatch(nil, fill: Color.themeAccent(colorTheme), isSelected: appearance.color == nil, help: "Theme Color")
                ForEach(FolderColor.allCases) { color in
                    swatch(color, fill: color.color, isSelected: appearance.color == color, help: LocalizedStringKey(color.displayName))
                }
            }

            LazyVGrid(columns: columns, spacing: Space.s2) {
                ForEach(FolderSymbol.allCases) { symbol in
                    let isSelected = (appearance.symbol ?? .folder) == symbol
                    Button {
                        model.folderAppearance.update(url) { $0.symbol = symbol == .folder ? nil : symbol }
                    } label: {
                        Image(systemName: symbol.systemName)
                            .font(.system(size: IconSize.inline))
                            .foregroundStyle(isSelected ? tint : Color.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: Layout.folderSymbolCell)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.small)
                                    .fill(isSelected ? Color.borderSubtle : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(symbol.displayName))
                    .accessibilityLabel(Text(LocalizedStringKey(symbol.displayName)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            Toggle("Color the folder name", isOn: Binding(
                get: { appearance.tintsName },
                set: { value in model.folderAppearance.update(url) { $0.tintsName = value } }
            ))
            .font(.system(size: TextSize.xs))
            .disabled(appearance.color == nil)

            HStack {
                Spacer()
                Button("Restore Default") { model.folderAppearance.reset(url) }
                    .disabled(appearance.isDefault)
            }
            .controlSize(.small)
        }
        .padding(Space.s4)
        .fixedSize()
    }

    private func swatch(_ color: FolderColor?, fill: Color, isSelected: Bool, help: LocalizedStringKey) -> some View {
        Button {
            model.folderAppearance.update(url) {
                $0.color = color
                if color == nil { $0.tintsName = false }
            }
        } label: {
            Circle()
                .fill(fill)
                .frame(width: Space.s4 + Space.s1, height: Space.s4 + Space.s1)
                .padding(Space.s1 / 2)
                .overlay(
                    Circle().strokeBorder(isSelected ? Color.textPrimary : Color.clear, lineWidth: 2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
/// 本地调试：设置 LITEMD_DEBUG_RENDER_DIR 后，把图标与颜色面板和几种文件夹样式离屏渲染为图片（屏幕锁定时也能核对）。
@MainActor
enum FolderAppearanceDebugRender {
    static func renderIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["LITEMD_DEBUG_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = URL(fileURLWithPath: "/tmp/LiteMD-Debug-Folder")
        model.folderAppearance.update(sample) { $0 = FolderAppearance(color: .orange, symbol: .ideas, tintsName: true) }

        let theme = model.settings.activeTheme
        let picker = FolderAppearancePicker(url: sample)
            .environment(model)
            .environment(\.colorTheme, theme)
            .background(Color.editorBackground)
        write(picker, to: directory.appendingPathComponent("folder-picker.png"))

        let rows = VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(Array(FolderColor.allCases.enumerated()), id: \.offset) { index, color in
                let symbol = FolderSymbol.allCases[(index * 3) % FolderSymbol.allCases.count]
                HStack(spacing: Space.s2) {
                    FolderIcon(appearance: FolderAppearance(color: color, symbol: symbol))
                    Text(LocalizedStringKey(symbol.displayName))
                        .foregroundStyle(index % 2 == 0 ? color.color : Color.textPrimary)
                }
            }
            HStack(spacing: Space.s2) {
                FolderIcon(appearance: FolderAppearance())
                Text("Folder").foregroundStyle(Color.textPrimary)
            }
        }
        .font(.system(size: TextSize.sm))
        .padding(Space.s4)
        .frame(width: Layout.sidebarIdealWidth, alignment: .leading)
        .environment(\.colorTheme, theme)
        .environment(\.colorScheme, theme.sidebarIsDark ? .dark : .light)
        .background(Color.sidebarBackground)
        write(rows, to: directory.appendingPathComponent("folder-rows.png"))
        model.folderAppearance.reset(sample)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
#endif
