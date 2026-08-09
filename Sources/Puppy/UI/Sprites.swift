import SwiftUI

/// 程序化像素小狗:每帧是 24×24 的字符位图,字符查调色板。
/// 造型是戴太空头盔的白色比熊 —— 正面半身,头盔占上半张图,宇航服肩膀托在下面。
/// 以后换真 PNG 美术,只要替换这个文件 + 把 MascotView 的 Canvas 换成
/// `Image(...).interpolation(.none)`,其余代码不用动。
enum Palette {
    /// 字符 → RGB。表里没有的字符('.')= 完全透明。
    static let rgb: [Character: (UInt8, UInt8, UInt8)] = [
        "D": (28, 40, 92),      // 描边 / 头盔颈环 深海军蓝
        "G": (74, 118, 205),    // 头盔玻璃 蓝
        "H": (176, 224, 255),   // 玻璃高光
        "P": (232, 122, 168),   // 玻璃上的粉色反光
        "W": (252, 251, 255),   // 白毛
        "S": (183, 196, 236),   // 毛的暗部,偏淡紫 —— 隔着蓝玻璃看到的白
        "K": (22, 26, 62),      // 眼睛 / 鼻头 / 嘴
        "U": (156, 178, 232),   // 宇航服
        "V": (104, 128, 196),   // 宇航服暗部
        "T": (242, 153, 166),   // 舌头
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

    /// 帧位图在这里就烤成 24×24 的 CGImage。
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

/// 字符位图 → 24×24 RGBA 图。放大交给 `.interpolation(.none)`,像素边缘保持硬朗。
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
    static let side = 24

    // 基础姿势:正面半身。y1–y16 是头盔(圆玻璃罩 + 罩里的白毛脑袋),y17 颈环,
    // y18–y23 宇航服的肩膀。颈环特意收窄到比头盔和肩膀都细,否则整个下半身会读成一个底座。
    // 脸上只留两处修饰:眼睛里那格白高光、跟鼻尖脱开一行的 `∨∨` 嘴。试过加腮红,
    // 白毛上两点红太跳,反而把干净的脸弄脏了。
    private static let base: [String] = [
        "........................",
        "........GGGGGGGG........",
        "......GGHHHHGGGGGG......",
        ".....GHHGGWWWWGPPGG.....",
        "....GHHGWWWWWWWWGPPG....",
        "....GHWWWWWWWWWWWGPG....",
        "...GHWWWWWWWWWWWWWWGG...",
        "...GWWWKWKWWWWKWKWWWG...",
        "...GWWWKKKWWWWKKKWWWG...",
        "...GWWWKKKWWWWKKKWWWG...",
        "...GWWWWWWWWWWWWWWWWG...",
        "...GWWWWWWKKKKWWWWWWG...",
        "....GWWWWWWKKWWWWWWG....",
        "....GWWWWWWWWWWWWWWG....",
        ".....GWWWWKWWKWWWWG.....",
        "......GSSSSSSSSSSG......",
        "......DDDDDDDDDDDD......",
        "....DDUUUUUUUUUUUUDD....",
        "...DUUUUUUUUUUUUUUUUD...",
        "..DUUVUUUUUUUUUUUUVUUD..",
        "..DUUVUUUUUUUUUUUUVUUD..",
        "..DVVVUUUUUUUUUUUUVVVD..",
        "..DVVVVVVVVVVVVVVVVVVD..",
        "...DDDDDDDDDDDDDDDDDD...",
    ]

    // 各部位的差分。用差分而不是重画整只狗,是为了让它们能自由组合。
    //
    // 闭眼有两套,因为「睡着」和「高兴」是两种情绪:睡觉是一道平的眼皮线,
    // 蹦跶时是往上弯的 `^ ^`。用同一套的话完成提示看起来会像打瞌睡。
    private static let eyesClosed: [Int: String] = [
        7: "...GWWWWWWWWWWWWWWWWG...",
        8: "...GWWWWWWWWWWWWWWWWG...",
        9: "...GWWWKKKWWWWKKKWWWG...",
    ]
    private static let eyesHappy: [Int: String] = [
        7: "...GWWWWWWWWWWWWWWWWG...",
        8: "...GWWWWKWWWWWWKWWWWG...",
        9: "...GWWWKWKWWWWKWKWWWG...",
    ]
    // 瞪眼:3 格宽撑到 4 格宽,高光跟着往外挪一格 —— 这是最扎眼的状态,要一眼看出不对劲。
    private static let eyesWide: [Int: String] = [
        7: "...GWWKWKKWWWWKKWKWWG...",
        8: "...GWWKKKKWWWWKKKKWWG...",
        9: "...GWWKKKKWWWWKKKKWWG...",
    ]
    // 正面像没有尾巴可摇,「在忙」就靠五官整体左右挪一格来演 —— 像在罩子里东张西望。
    private static let lookLeft: [Int: String] = [
        7: "...GWWKWKWWWWKWKWWWWG...",
        8: "...GWWKKKWWWWKKKWWWWG...",
        9: "...GWWKKKWWWWKKKWWWWG...",
        11: "...GWWWWWKKKKWWWWWWWG...",
        12: "....GWWWWWKKWWWWWWWG....",
        13: "....GWWWWWWWWWWWWWWG....",
        14: ".....GWWWKWWKWWWWWG.....",
    ]
    private static let lookRight: [Int: String] = [
        7: "...GWWWWKWKWWWWKWKWWG...",
        8: "...GWWWWKKKWWWWKKKWWG...",
        9: "...GWWWWKKKWWWWKKKWWG...",
        11: "...GWWWWWWWKKKKWWWWWG...",
        12: "....GWWWWWWWKKWWWWWG....",
        13: "....GWWWWWWWWWWWWWWG....",
        14: ".....GWWWWWKWWKWWWG.....",
    ]
    // 张嘴的同时要把鼻尖那两格擦掉,否则鼻子和嘴糊成一大坨黑,五官就没了。
    private static let mouthOpen: [Int: String] = [
        12: "....GWWWWWWWWWWWWWWG....",
        13: "....GWWWWWKKKKWWWWWG....",
        14: ".....GWWWWKTTKWWWWG.....",
    ]

    private static func pose(_ patches: [Int: String]...) -> [String] {
        var rows = base
        for patch in patches {
            for (index, row) in patch { rows[index] = row }
        }
        return rows
    }

    // MARK: - 每个状态一组帧
    //
    // 起伏一律走 yOffsets,不去动帧位图 —— 位图整行平移会把最下面一行挤出画布,
    // 而身体现在一直画到 y23。offset 一律取整格(一格 = 4pt),半格会让放大后的像素行
    // 一会儿 4pt 一会儿 5pt,边缘就毛了。

    /// 全空闲:闭眼 + 呼吸起伏 + 飘 z。
    static let sleeping = Sprite(
        frames: [pose(eyesClosed), pose(eyesClosed)],
        fps: 1,
        yOffsets: [0, 1],
        bubble: "z",
        bubbleColor: Color(white: 0.65)
    )

    /// 有 session 在跑:左顾右盼 + 轻微起伏。
    static let working = Sprite(
        frames: [pose(lookLeft), pose(), pose(lookRight), pose()],
        fps: 5,
        yOffsets: [-1, 0, -1, 0],
        bubble: nil,
        bubbleColor: .clear
    )

    /// 有 session 在等用户:瞪大眼睛 + 上下跳 + "!"。最高优先级,要最扎眼。
    static let alert = Sprite(
        frames: [pose(eyesWide, mouthOpen), pose(eyesWide)],
        fps: 4,
        yOffsets: [-2, 1],
        bubble: "!",
        bubbleColor: Color(red: 0.95, green: 0.35, blue: 0.30)
    )

    /// 完成提示的绿色。徽标和 celebrating 的气泡共用,免得两处调色调歪。
    static let doneColor = Color(red: 0.30, green: 0.78, blue: 0.45)

    /// 刚完成:张嘴吐舌 + 笑成一对 `^ ^` + 蹦跶 + "✓"。
    static let celebrating = Sprite(
        frames: [pose(mouthOpen, eyesHappy), pose(mouthOpen)],
        fps: 6,
        // 画布上下各只有 8pt 余量(112 窗口 / 96 画布),4pt 一格 —— 跳到 -2 就顶到头了。
        yOffsets: [-2, 0],
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
