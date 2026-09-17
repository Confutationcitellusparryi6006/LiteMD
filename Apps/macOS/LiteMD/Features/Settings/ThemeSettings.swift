import AppKit
import LiteMDDomain
import SwiftUI

/// 设置 → 主题：外观模式 + 主题卡片。点击卡片用于当前外观；卡片右上角的太阳 / 月亮分别指定浅色、深色模式的主题。
struct ThemeSettings: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.flexible(), spacing: Space.s4), GridItem(.flexible(), spacing: Space.s4)]

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s3) {
                    Text("Appearance")
                        .font(.system(size: TextSize.sm, weight: .semibold))
                    Picker("Appearance", selection: $settings.theme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                Text("Click a theme to use it now. Use the sun and moon to choose the themes for light and dark mode.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)

                LazyVGrid(columns: columns, spacing: Space.s4) {
                    ForEach(ColorTheme.allCases) { theme in
                        ThemePreviewCard(
                            theme: theme,
                            isActive: settings.activeTheme == theme,
                            isLightTheme: settings.lightTheme == theme,
                            isDarkTheme: settings.darkTheme == theme,
                            select: { settings.useThemeForCurrentAppearance(theme) },
                            assignLight: { settings.lightTheme = theme },
                            assignDark: { settings.darkTheme = theme }
                        )
                    }
                }
            }
            .padding(Space.s6)
        }
    }
}

/// Bear 风格的主题卡片：卡片本身就是该主题下的正文预览。
private struct ThemePreviewCard: View {
    let theme: ColorTheme
    let isActive: Bool
    let isLightTheme: Bool
    let isDarkTheme: Bool
    let select: () -> Void
    let assignLight: () -> Void
    let assignDark: () -> Void
    @State private var isHovering = false

    var body: some View {
        let colors = theme.colors

        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                HStack(spacing: 0) {
                    // 深色侧栏搭配浅色编辑区的主题，在左侧显示侧栏颜色。
                    if theme.sidebarIsDark != theme.isDark {
                        Rectangle()
                            .fill(color(theme.sidebarBackground))
                            .frame(width: Space.s3)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(LocalizedStringKey(theme.displayName))
                            .font(.system(size: TextSize.lg, weight: .semibold))
                            .foregroundStyle(color(colors.heading))
                        sample(colors)
                            .font(.system(size: TextSize.sm))
                            .lineSpacing(Space.s1)
                            .foregroundStyle(color(colors.foreground))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: Layout.themeCardHeight, alignment: .topLeading)
                .background(color(colors.background))
                .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.large)
                        .strokeBorder(isActive ? Color.brand : color(colors.border), lineWidth: isActive ? 3 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.large))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey(theme.displayName)))
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if isHovering || isLightTheme || isDarkTheme {
                HStack(spacing: Space.s1) {
                    slotButton(symbol: isLightTheme ? "sun.max.fill" : "sun.max", isOn: isLightTheme, help: "Use for Light Mode", action: assignLight)
                    slotButton(symbol: isDarkTheme ? "moon.fill" : "moon", isOn: isDarkTheme, help: "Use for Dark Mode", action: assignDark)
                }
                .padding(Space.s3)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func sample(_ colors: ThemeColors) -> Text {
        Text(verbatim: "Lorem ipsum ")
            + Text(verbatim: "dolor sit amet").bold().foregroundColor(color(colors.heading))
            + Text(verbatim: ", consectetur adipiscing elit. Mauris iaculis ")
            + Text(verbatim: "semper").foregroundColor(color(colors.accent))
            + Text(verbatim: " pharetra.")
    }

    private func slotButton(symbol: String, isOn: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.inline, weight: .medium))
                .foregroundStyle(isOn ? color(theme.colors.accent) : color(theme.colors.tertiary))
                .frame(width: Space.s6, height: Space.s6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(hexString: hex) ?? .labelColor)
    }
}
