import AppKit
import SwiftUI

/// 编辑区 / 预览分栏。
///
/// 不使用 HSplitView：它无法指定初始比例，且增删子视图时会重建编辑器。
/// 这里左侧视图始终处于同一位置，切换模式只增删右侧预览；分隔线可拖动，比例会被记住。
struct EditorSplitView<Leading: View, Trailing: View>: View {
    let showsTrailing: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @AppStorage("editor.splitRatio") private var ratio = 0.5
    @State private var dragStartRatio: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = max(proxy.size.width, 1)
            let minimum = Layout.editorMinimumWidth
            let leadingWidth = showsTrailing
                ? min(max(total * ratio, minimum), max(minimum, total - minimum))
                : total

            HStack(spacing: 0) {
                leading()
                    .frame(width: leadingWidth)

                if showsTrailing {
                    SplitDivider()
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStartRatio ?? ratio
                                    if dragStartRatio == nil { dragStartRatio = ratio }
                                    let proposed = start + value.translation.width / total
                                    ratio = min(max(proposed, minimum / total), 1 - minimum / total)
                                }
                                .onEnded { _ in dragStartRatio = nil }
                        )
                        .onTapGesture(count: 2) { ratio = 0.5 }

                    trailing()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct SplitDivider: View {
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // 可拖动区域比可见线宽。
                Color.clear
                    .frame(width: Space.s2)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHovering else { return }
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
            .help("Drag to resize. Double-click to reset.")
    }
}
