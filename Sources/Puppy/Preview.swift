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
            row(103, "agentic-research", .idle, ago: 8, now: now, completed: true,
                note: "补上了缺的重试逻辑,测试全过"),
            row(104, "dotfiles", .idle, ago: 5400, now: now),
        ]
    }

    /// 专门喂给气泡栈:6 个待办,超过 `maxVisible` 才画得出「还有 N 个」那一条。
    /// 「在等你」不要排满 5 条 —— 排满了「刚跑完」永远被挤进折叠里,
    /// 带 hook 摘要的那条就渲不出来,而它正是最需要目视确认版面的一条。
    private static func sampleStackRows() -> [SessionRow] {
        let now = Date()
        return [
            row(101, "puppy", .waiting, "permission prompt", ago: 2400, now: now),
            row(102, "agentic-research", .waiting, "plan approval", ago: 184, now: now),
            row(103, "cse-csp-lecture", .waiting, ago: 95, now: now),
            row(104, "dotfiles", .waiting, "edit file", ago: 40, now: now),
            // 一条带 Stop hook 摘要、一条没有 —— 装没装 hook 两种样子一起看。
            row(106, "paper-osdi", .idle, ago: 8, now: now, completed: true,
                note: "评审意见都回完了,主要改了 §4 的实验设置"),
            row(107, "infra-terraform", .idle, ago: 30, now: now, completed: true),
        ]
    }

    private static func row(_ pid: Int32, _ name: String, _ status: SessionStatus,
                            _ waiting: String? = nil, ago: TimeInterval, now: Date,
                            completed: Bool = false, note: String? = nil) -> SessionRow {
        let info = SessionInfo(
            pid: pid, sessionId: "preview-\(pid)", cwd: "/Users/wxd/lab/personal/\(name)", name: "\(name)-a1",
            kind: "interactive", entrypoint: "cli", version: "2.1.226",
            status: status, waitingFor: waiting,
            startedAt: now.addingTimeInterval(-3600),
            statusUpdatedAt: now.addingTimeInterval(-ago)
        )
        let at = now.addingTimeInterval(-ago)
        return SessionRow(
            info: info,
            completedAt: completed ? at : nil,
            note: note.map { SidecarNote(sessionId: "preview-\(pid)", summary: $0, abnormal: nil, at: at) })
    }
}

/// 单帧渲染,含气泡和纵向偏移 —— 跟 MascotLayerView 里播的是同一套数据。
struct MascotFrameView: View {
    let skin: MascotSkin
    let sprite: Sprite
    let index: Int
    var doneBadge: Bool = false

    var body: some View {
        // 摆位一律走 MascotMetrics 上的常量和皮肤上的锚点,连画布内缩都照抄 ——
        // 预览要能拿来判断气泡会不会压到耳朵,它就得跟真窗口逐点一致。
        ZStack(alignment: .topLeading) {
            PixelCanvas(image: sprite.image(at: index), smooth: skin.smooth)
                .frame(width: MascotMetrics.canvas, height: MascotMetrics.canvas)
                .offset(x: MascotMetrics.inset,
                        y: MascotMetrics.inset
                            + sprite.yOffset(at: index) * (MascotMetrics.canvas / CGFloat(skin.side)))
            if let bubble = sprite.bubble {
                MascotBubbleText(bubble, color: sprite.bubbleColor, skin: skin)
            }
            if doneBadge {
                MascotDoneBadge(bobbing: !index.isMultiple(of: 2), skin: skin)
            }
        }
        .frame(width: MascotMetrics.side, height: MascotMetrics.side)
    }
}

// MARK: - 预览专用的 SwiftUI 视图
//
// 真窗口里跑的是 `MascotLayerView`(CALayer + CA 动画,为了省电)。下面这几个是
// **只给 `--render` 用**的 SwiftUI 等价物 —— 离屏渲染要的是「给我第 N 帧的静态图」,
// 用 ImageRenderer 出图最省事,而且它一次性跑完就退出,没有功耗可言。
// 两边的摆位都以 `MascotMetrics` 和皮肤锚点为准,所以渲出来跟真窗口逐点一致。

/// 状态气泡("z" / "!")。摊在皮肤指定的那段头顶空地上,文字在里头居中 ——
/// 定宽的框才能保证换个字形也不跑偏。
struct MascotBubbleText: View {
    let text: String
    let color: Color
    let skin: MascotSkin

    init(_ text: String, color: Color, skin: MascotSkin) {
        self.text = text
        self.color = color
        self.skin = skin
    }

    var body: some View {
        let cell = MascotMetrics.cell(skin)
        let cells = skin.bubbleCells
        Text(text)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            .frame(width: CGFloat(cells.count) * cell, height: 28)
            .offset(x: MascotMetrics.inset + CGFloat(cells.lowerBound) * cell, y: 0)
    }
}

/// ✓ 徽标。要和状态气泡分开挂,两个同时出现时才不打架。
struct MascotDoneBadge: View {
    var bobbing: Bool
    let skin: MascotSkin

    var body: some View {
        let cell = MascotMetrics.cell(skin)
        Text("✓")
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(Sprites.doneColor)
            .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
            .offset(x: MascotMetrics.inset + CGFloat(skin.badgeCell) * cell, y: bobbing ? -3 : 0)
    }
}

/// 画一帧已经烤好的位图。像素皮肤用 `.none` 保证放大后仍是硬边像素;
/// 卡通等高分辨率皮肤(skin.json 里 `"smooth": true`)换平滑插值,缩小时才不出锯齿。
struct PixelCanvas: View {
    let image: CGImage?
    var smooth: Bool = false

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(smooth ? .high : .none)
                .antialiased(smooth)
                .resizable()
        }
    }
}
