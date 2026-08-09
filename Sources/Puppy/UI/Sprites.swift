import SwiftUI

/// 程序化像素小狗:每帧是 16×16 的字符位图,字符查调色板。
/// 以后换真 PNG 美术,只要替换这个文件 + 把 MascotView 的 Canvas 换成
/// `Image(...).interpolation(.none)`,其余代码不用动。
enum Palette {
    /// 字符 → RGB。表里没有的字符('.')= 完全透明。
    static let rgb: [Character: (UInt8, UInt8, UInt8)] = [
        "B": (194, 140, 84),    // 身体棕
        "D": (84, 51, 26),      // 描边深棕
        "W": (252, 245, 232),   // 口鼻 / 爪
        "K": (26, 20, 18),      // 眼睛 / 鼻头
        "P": (242, 153, 166),   // 舌头 / 耳内
    ]
}

struct Sprite {
    let frames: [[String]]
    let fps: Double
    /// 与 frames 一一对应的纵向偏移(像素格数),用来做跳动 / 呼吸。
    let yOffsets: [Double]
    /// 头顶气泡,nil = 不画。
    let bubble: String?
    let bubbleColor: Color

    /// 帧位图在这里就烤成 16×16 的 CGImage。
    /// 每帧只画一次,之后每一帧都只是一次缩放 blit —— 不再有逐格的矢量填充。
    let images: [CGImage]

    init(frames: [[String]], fps: Double, yOffsets: [Double], bubble: String?, bubbleColor: Color) {
        self.frames = frames
        self.fps = fps
        self.yOffsets = yOffsets
        self.bubble = bubble
        self.bubbleColor = bubbleColor
        self.images = frames.compactMap(PixelRaster.image(from:))
    }

    func frame(at index: Int) -> [String] { frames[index % frames.count] }
    func image(at index: Int) -> CGImage? {
        images.isEmpty ? nil : images[index % images.count]
    }
    func yOffset(at index: Int) -> Double { yOffsets.isEmpty ? 0 : yOffsets[index % yOffsets.count] }
}

/// 字符位图 → 16×16 RGBA 图。放大交给 `.interpolation(.none)`,像素边缘保持硬朗。
enum PixelRaster {
    static func image(from rows: [String]) -> CGImage? {
        let side = Sprites.side
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for (y, row) in rows.enumerated() where y < side {
            for (x, character) in row.enumerated() where x < side {
                guard let (r, g, b) = Palette.rgb[character] else { continue }
                let offset = (y * side + x) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

enum Sprites {
    static let side = 16

    // 基础姿势:3/4 侧面,面朝右。尾巴在左上,头在右,四条腿在下。
    private static let base: [String] = [
        "................",
        "........DDDDD...",
        ".......DDBBBBBD.",
        "......DDDBBBBBBD",
        ".D....DPDBKBBKBD",
        "DBD...DPDBBBBBBD",
        "DBBDDDDDDBWWWWBD",
        ".DBBBBBBBBBWKWBD",
        "..DBBBBBBBBDWWBD",
        "..DBBBBBBBBDDDD.",
        "..DBBBBBBBBD....",
        "..DBBBBBBBBD....",
        "..DBDDDDBBBD....",
        "..DBD..DBBBD....",
        "..DWD..DWWWD....",
        "..DDD..DDDDD....",
    ]

    // 各部位的差分。用差分而不是重画整只狗,是为了让它们能自由组合。
    // 闭眼:眼睛那一行清空,眼线下移一格 —— 读起来才像垂下的眼皮,
    // 单纯把黑点换成深棕在 6px 的格子上几乎看不出区别。
    private static let eyesClosed: [Int: String] = [
        4: ".D....DPDBBBBBBD",
        5: "DBD...DPDBKBBKBD",
    ]
    private static let eyesWide: [Int: String] = [
        5: "DBD...DPDBKBBKBD",
    ]
    private static let tailUp: [Int: String] = [
        3: "..D...DDDBBBBBBD",
        4: ".DBD..DPDBKBBKBD",
        5: ".DBD..DPDBBBBBBD",
        6: ".DBDDDDDDBWWWWBD",
    ]
    private static let legsRun: [Int: String] = [
        13: ".DBD...DBBBD....",
        14: ".DWD....DBBD....",
        15: ".DDD....DWWD....",
    ]
    private static let mouthOpen: [Int: String] = [
        8: "..DBBBBBBBBDKKBD",
        9: "..DBBBBBBBBDPPD.",
    ]

    private static func pose(_ patches: [Int: String]...) -> [String] {
        var rows = base
        for patch in patches {
            for (index, row) in patch { rows[index] = row }
        }
        return rows
    }

    private static func sunk(_ rows: [String]) -> [String] {
        [String(repeating: ".", count: side)] + rows.dropLast()
    }

    // MARK: - 每个状态一组帧

    /// 全空闲:闭眼 + 呼吸起伏 + 飘 z。
    static let sleeping = Sprite(
        frames: [pose(eyesClosed), sunk(pose(eyesClosed))],
        fps: 1,
        yOffsets: [0, 0],
        bubble: "z",
        bubbleColor: Color(white: 0.65)
    )

    /// 有 session 在跑:小跑 + 摇尾。
    static let working = Sprite(
        frames: [pose(), pose(tailUp, legsRun), pose(tailUp), pose(legsRun)],
        fps: 5,
        yOffsets: [0, -0.3, 0, -0.3],
        bubble: nil,
        bubbleColor: .clear
    )

    /// 有 session 在等用户:睁大眼睛 + 上下跳 + "!"。最高优先级,要最扎眼。
    static let alert = Sprite(
        frames: [pose(eyesWide, mouthOpen, tailUp), pose(eyesWide, tailUp)],
        fps: 4,
        yOffsets: [-1.2, 0.4],
        bubble: "!",
        bubbleColor: Color(red: 0.95, green: 0.35, blue: 0.30)
    )

    /// 完成提示的绿色。徽标和 celebrating 的气泡共用,免得两处调色调歪。
    static let doneColor = Color(red: 0.30, green: 0.78, blue: 0.45)

    /// 刚完成:张嘴吐舌 + 蹦跶 + "✓"。
    static let celebrating = Sprite(
        frames: [pose(mouthOpen, tailUp), pose(mouthOpen, tailUp, legsRun)],
        fps: 6,
        yOffsets: [-1.5, 0],
        bubble: "✓",
        bubbleColor: doneColor
    )

    static func sprite(for state: MascotState) -> Sprite {
        switch state {
        case .alert: return alert
        case .working: return working
        case .celebrating: return celebrating
        case .sleeping: return sleeping
        }
    }
}
