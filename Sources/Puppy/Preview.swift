import AppKit
import SwiftUI

/// `--render <dir>`:把每个状态的每一帧离屏渲染成 PNG。
/// 纯粹是开发期的目视检查工具 —— 不用截屏权限就能看清小狗到底长什么样。
@MainActor
enum Preview {

    /// `skinID` 给了就渲染那套磁盘皮肤 —— 自己画的皮肤可以先渲出来看,不用装上去重启。
    static func renderAll(to directory: String, skinID: String? = nil) {
        _ = NSApplication.shared      // SwiftUI 离屏渲染也要求 AppKit 已初始化
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let skin = skinID.flatMap { id in SkinLibrary.all().first { $0.id == id } } ?? Sprites.builtIn
        if let skinID, skin.id != skinID {
            print("没有叫 \(skinID) 的皮肤,改用内置的。`--skins` 可以看有哪些")
        }

        for state in [MascotState.sleeping, .working, .celebrating, .alert] {
            write(strip(skin, for: state), to: base.appendingPathComponent("mascot-\(state.rawValue).png"))
        }
        // 「一个跑完了但别的还在跑 / 还在等你」—— ✓ 徽标单挂右上角的两种叠加情形。
        write(strip(skin, for: .working, doneBadge: true),
              to: base.appendingPathComponent("mascot-working-done.png"))
        write(strip(skin, for: .alert, doneBadge: true),
              to: base.appendingPathComponent("mascot-alert-done.png"))

        // 气泡栈:小狗在左边和在右边两种朝向都画一遍,顺便撑到溢出看「还有 N 个」。
        let stackStore = SessionStore()
        stackStore.installPreviewRows(Self.sampleStackRows())
        let bubbles = HStack(alignment: .bottom, spacing: 24) {
            BubbleStackView(store: stackStore, tailOnRight: true, animated: false)
            BubbleStackView(store: stackStore, tailOnRight: false, animated: false)
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

    private static func strip(_ skin: MascotSkin, for state: MascotState,
                              doneBadge: Bool = false) -> some View {
        let sprite = skin.sprite(for: state)
        return HStack(spacing: 4) {
            ForEach(0..<sprite.frameCount, id: \.self) { index in
                MascotFrameView(skin: skin, sprite: sprite, index: index, doneBadge: doneBadge)
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

    private static func sampleRows() -> [SessionRow] {
        let now = Date()
        return [
            row(101, "puppy", .waiting, "permission prompt", ago: 184, now: now),
            row(102, "cse-csp-lecture", .busy, ago: 42, now: now),
            row(103, "agentic-research", .idle, ago: 8, now: now, completed: true),
            row(104, "dotfiles", .idle, ago: 5400, now: now),
        ]
    }

    /// 专门喂给气泡栈:7 个待办,超过 `maxVisible` 才画得出「还有 N 个」那一条。
    private static func sampleStackRows() -> [SessionRow] {
        let now = Date()
        return [
            row(101, "puppy", .waiting, "permission prompt", ago: 2400, now: now),
            row(102, "agentic-research", .waiting, "plan approval", ago: 184, now: now),
            row(103, "cse-csp-lecture", .waiting, ago: 95, now: now),
            row(104, "dotfiles", .waiting, "edit file", ago: 40, now: now),
            row(105, "kernel-bpf", .waiting, ago: 12, now: now),
            row(106, "paper-osdi", .idle, ago: 8, now: now, completed: true),
            row(107, "infra-terraform", .idle, ago: 30, now: now, completed: true),
        ]
    }

    private static func row(_ pid: Int32, _ name: String, _ status: SessionStatus,
                            _ waiting: String? = nil, ago: TimeInterval, now: Date,
                            completed: Bool = false) -> SessionRow {
        let info = SessionInfo(
            pid: pid, sessionId: nil, cwd: "/Users/wxd/lab/personal/\(name)", name: "\(name)-a1",
            kind: "interactive", entrypoint: "cli", version: "2.1.226",
            status: status, waitingFor: waiting,
            startedAt: now.addingTimeInterval(-3600),
            statusUpdatedAt: now.addingTimeInterval(-ago)
        )
        return SessionRow(info: info, completedAt: completed ? now.addingTimeInterval(-ago) : nil)
    }
}

/// 单帧渲染,含气泡和纵向偏移 —— 跟 MascotView 里跑的是同一套数据。
private struct MascotFrameView: View {
    let skin: MascotSkin
    let sprite: Sprite
    let index: Int
    var doneBadge: Bool = false

    var body: some View {
        // 摆位一律走 MascotView 上的常量和皮肤上的锚点,连画布内缩都照抄 ——
        // 预览要能拿来判断气泡会不会压到耳朵,它就得跟真窗口逐点一致。
        ZStack(alignment: .topLeading) {
            PixelCanvas(image: sprite.image(at: index))
                .frame(width: MascotView.canvas, height: MascotView.canvas)
                .offset(x: MascotView.inset,
                        y: MascotView.inset
                            + sprite.yOffset(at: index) * (MascotView.canvas / CGFloat(skin.side)))
            if let bubble = sprite.bubble {
                MascotBubbleText(bubble, color: sprite.bubbleColor, skin: skin)
            }
            if doneBadge {
                MascotDoneBadge(bobbing: !index.isMultiple(of: 2), skin: skin)
            }
        }
        .frame(width: MascotView.side, height: MascotView.side)
    }
}
