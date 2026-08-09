import AppKit
import SwiftUI

/// `--render <dir>`:把每个状态的每一帧离屏渲染成 PNG。
/// 纯粹是开发期的目视检查工具 —— 不用截屏权限就能看清小狗到底长什么样。
@MainActor
enum Preview {

    static func renderAll(to directory: String) {
        _ = NSApplication.shared      // SwiftUI 离屏渲染也要求 AppKit 已初始化
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for state in [MascotState.sleeping, .working, .celebrating, .alert] {
            write(strip(for: state), to: base.appendingPathComponent("mascot-\(state.rawValue).png"))
        }
        // 「一个跑完了但别的还在跑 / 还在等你」—— ✓ 徽标单挂右上角的两种叠加情形。
        write(strip(for: .working, doneBadge: true),
              to: base.appendingPathComponent("mascot-working-done.png"))
        write(strip(for: .alert, doneBadge: true),
              to: base.appendingPathComponent("mascot-alert-done.png"))

        // 气泡:小狗在左边和在右边两种朝向都画一遍。
        let bubbles = VStack(alignment: .leading, spacing: 10) {
            BubbleView(announcement: sampleAnnouncement(.waiting("permission prompt")), tailOnRight: true)
            BubbleView(announcement: sampleAnnouncement(.done), tailOnRight: false)
        }
        .padding(12)
        .background(Color(white: 0.18))
        write(bubbles, to: base.appendingPathComponent("bubble.png"))

        let store = SessionStore()
        store.installPreviewRows(Self.sampleRows())
        let list = SessionListView(store: store, onSelect: { _ in }, frozenNow: Date())
            .padding(16)
            .background(Color(white: 0.18))
        write(list, to: base.appendingPathComponent("list.png"))

        print("已渲染到 \(base.path)")
    }

    private static func strip(for state: MascotState, doneBadge: Bool = false) -> some View {
        let sprite = Sprites.sprite(for: state)
        return HStack(spacing: 4) {
            ForEach(Array(sprite.frames.indices), id: \.self) { index in
                MascotFrameView(sprite: sprite, index: index, doneBadge: doneBadge)
            }
        }
        .padding(8)
        .background(Color(white: 0.18))
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("渲染失败: \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    private static func sampleAnnouncement(_ kind: Announcement.Kind) -> Announcement {
        Announcement(id: 1, kind: kind, pid: 101,
                     name: kind == .done ? "puppy-6e" : "agentic-research-67",
                     expiresAt: Date().addingTimeInterval(12))
    }

    private static func sampleRows() -> [SessionRow] {
        let now = Date()
        func info(_ pid: Int32, _ name: String, _ status: SessionStatus, _ waiting: String? = nil, ago: TimeInterval) -> SessionInfo {
            SessionInfo(pid: pid, sessionId: nil, cwd: "/Users/wxd/lab/personal/\(name)", name: "\(name)-a1",
                        kind: "interactive", entrypoint: "cli", version: "2.1.226",
                        status: status, waitingFor: waiting,
                        startedAt: now.addingTimeInterval(-3600),
                        statusUpdatedAt: now.addingTimeInterval(-ago))
        }
        return [
            SessionRow(info: info(101, "puppy", .waiting, "permission prompt", ago: 184), completedAt: nil),
            SessionRow(info: info(102, "cse-csp-lecture", .busy, ago: 42), completedAt: nil),
            SessionRow(info: info(103, "agentic-research", .idle, ago: 8), completedAt: now.addingTimeInterval(-8)),
            SessionRow(info: info(104, "dotfiles", .idle, ago: 5400), completedAt: nil),
        ]
    }
}

/// 单帧渲染,含气泡和纵向偏移 —— 跟 MascotView 里跑的是同一套数据。
private struct MascotFrameView: View {
    let sprite: Sprite
    let index: Int
    var doneBadge: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PixelCanvas(image: sprite.image(at: index))
                .frame(width: MascotView.canvas, height: MascotView.canvas)
                .offset(y: sprite.yOffset(at: index) * (MascotView.canvas / CGFloat(Sprites.side)))
            if let bubble = sprite.bubble {
                Text(bubble)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(sprite.bubbleColor)
                    .offset(x: -2, y: -4)
            }
            if doneBadge {
                Text("✓")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Sprites.doneColor)
                    .offset(x: MascotView.side - 30, y: index.isMultiple(of: 2) ? -6 : -9)
            }
        }
        .frame(width: MascotView.side, height: MascotView.side)
    }
}
