import SwiftUI

/// 点开小狗看到的 session 列表。整个面板永远拿不到键盘焦点(nonactivating panel),
/// 所以交互只有点击 —— 没有任何需要打字的地方。
struct SessionListView: View {
    @ObservedObject var store: SessionStore
    var onSelect: (SessionRow) -> Void
    /// 只给 `--render` 用:固定住「现在」,免得离屏渲染要依赖 TimelineView 的时钟。
    var frozenNow: Date? = nil

    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 46
    static let headerHeight: CGFloat = 24
    static let maxBodyHeight: CGFloat = 5 * rowHeight
    /// 上下 padding(6+6)+ header + 分隔线。
    private static let chrome: CGFloat = 12 + headerHeight + 1

    /// 面板该多高。SessionListController 用它算窗口 frame。
    static func height(rowCount: Int) -> CGFloat {
        let body = rowCount == 0 ? 52 : min(maxBodyHeight, CGFloat(rowCount) * rowHeight)
        return chrome + body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if store.rows.isEmpty {
                Text("没有运行中的 Claude Code session")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else if let frozenNow {
                rowsStack(now: frozenNow)      // 离屏渲染时不套 ScrollView(它在 ImageRenderer 里不出内容)
            } else {
                // 「已等待 X」这类标签需要每秒刷新 —— 但这个 TimelineView 只在面板打开时存在,
                // 面板一关时钟就没了,常驻状态下不会有任何定时唤醒。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    rowList(now: context.date)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func rowList(now: Date) -> some View {
        ScrollView {
            rowsStack(now: now)
        }
        .frame(height: min(Self.maxBodyHeight, CGFloat(store.rows.count) * Self.rowHeight))
    }

    // 同时最多也就几个 session,VStack 就够了 —— LazyVStack 的惰性在这里没有收益。
    private func rowsStack(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(store.rows) { row in
                SessionRowView(row: row, now: now)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(row) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Code")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(store.rows.count) session")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: SessionListView.headerHeight)
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    let now: Date

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(row.display.icon)
                .font(.system(size: 15))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.info.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.info.shortCwd)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(row.display.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let duration = row.stateDuration(now: now) {
                    Text(CLI.format(duration: duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            // 给状态列封顶,免得 waitingFor 很长时把项目名挤没。
            .frame(maxWidth: 140, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: SessionListView.rowHeight)
        .background(hovering ? Color.primary.opacity(0.08) : .clear)
        .onHover { hovering = $0 }
    }

    private var tint: Color {
        switch row.display {
        case .waiting: return Color(red: 0.95, green: 0.45, blue: 0.30)
        case .busy: return Color(red: 0.35, green: 0.60, blue: 0.95)
        case .completed: return Color(red: 0.30, green: 0.72, blue: 0.45)
        case .idle, .other: return .secondary
        }
    }
}
