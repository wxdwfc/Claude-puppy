import SwiftUI

/// 程序化像素小狗:每帧是 24×24 的字符位图,字符查调色板。
/// 造型是戴太空头盔的白色狗狗 —— 正面半身,头盔占上半张图,宇航服肩膀托在下面。
/// 「是只狗」全靠那对从头顶两侧往外披下来、四面描了边的垂耳。
/// 去掉耳朵,圆脑袋 + 两只豆豆眼 + 一个鼻头,读出来就是只小熊。
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
        // 耳朵。整个调色板都是冷色,所以这一档特意偏暖 —— 冷色系里再挑一档浅蓝灰,
        // 耳朵会连着头盔玻璃一起糊成一片浅色,读不出是搭在脸上的另一块东西。
        "E": (196, 186, 205),
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

    // 基础姿势:正面半身。y0–y15 是头盔(D 描出罩沿,罩里是白毛脑袋),y16 颈环,
    // y17–y23 宇航服的肩膀。颈环特意收窄到比头盔和肩膀都细,否则整个下半身会读成一个底座。
    //
    // 「圆」是两层各自都要圆,少一层都不行:
    // 罩子 20 宽 × 16 行,行宽 10-14-16-18-18-20×6-18-18-16-14-10 上下完全对称;
    // 脑袋 14 宽 × 12 行(y3–y14),四角同样一格一格收。
    // 试过只把罩子撑圆、脑袋留在 10 格,脸在大罩子里缩成一小团,五官反而显得又挤又大;
    // 更早一版是 24 宽 × 15 高的扁罩子 —— 那个是「憨」的正主。
    //
    // 耳朵挪到额头两侧(y4–y9),不再一路垂到脸颊 —— 狗耳本来就长在眼睛上方,
    // 而且让开了下半张脸,眼睛才能拿到 14 格的完整宽度。眼睛因此画成 4 宽 × 3 高、
    // 上下两行各削掉两角的圆眼,并压到下半部:大脑门 + 低眼位是最讨喜的比例。
    // 试过 3 宽 × 2 高的扁眼,配上左上角的高光,直接读成了眯眼生气 —— 眼睛得是圆的。
    // 耳朵**四面都用 D 描边**,内侧那条尤其不能省 —— 分离感靠的是硬边不是明暗。
    // 试过只填浅灰、试过只描外侧、试过内侧改用一列投影,三版的耳朵都贴着罩沿
    // 读成了头盔内衬,整只狗又变回一颗白球。
    //
    // 脸上只留两处修饰:圆眼里那格白反光、跟鼻尖脱开一行的 `∨∨` 嘴。
    // 试过给鼻吻勾一圈轮廓,两道竖线在白脸上直接读成了泪痕,不如空着让耳朵去交代品种。
    private static let base: [String] = [
        ".......DHHGGGGPPD.......",
        ".....DHHGGGGGGGGPPD.....",
        "....DHHGGGGGGGGGGPPD....",
        "...DHHGGWWWWWWWWGGPPD...",
        "...DHHDEDWWWWWWDEDPPD...",
        "..DHGDEEDWWWWWWDEEDGPD..",
        "..DGDEEDWWWWWWWWDEEDGD..",
        "..DGDEEDWWWWWWWWDEEDGD..",
        "..DGDEDWWWWWWWWWWDEDGD..",
        "..DGGDDWKKWWWWKKWDDGGD..",
        "..DGGWWKWKKWWKWKKWWGGD..",
        "...DGWWWKKWWWWKKWWWGD...",
        "...DGGWWWWWKKWWWWWGGD...",
        "....DGGWWWKWWKWWWGGD....",
        ".....DGGWWWWWWWWGGD.....",
        ".......DGSSSSSSGD.......",
        "......DDDDDDDDDDDD......",
        "....DDUUUUUUUUUUUUDD....",
        "...DUUUUUUUUUUUUUUUUD...",
        "..DUUVUUUUUUUUUUUUVUUD..",
        "..DUUVUUUUUUUUUUUUVUUD..",
        "..DVVVUUUUUUUUUUUUVVVD..",
        "..DVVVVVVVVVVVVVVVVVVD..",
        "...DDDDDDDDDDDDDDDDDD...",
    ]

    private static let eyesClosed: [Int: String] = [
        9: "..DGGDDWWWWWWWWWWDDGGD..",
        10: "..DGGWWKKKKWWKKKKWWGGD..",
        11: "...DGWWWWWWWWWWWWWWGD...",
    ]
    private static let eyesHappy: [Int: String] = [
        9: "..DGGDDWWWWWWWWWWDDGGD..",
        10: "..DGGWWWKKWWWWKKWWWGGD..",
        11: "...DGWWKWWKWWKWWKWWGD...",
    ]
    // 瞪眼:圆眼上下两行的角补满,连反光一起吃掉 —— 这是最扎眼的状态,要一眼看出不对劲。
    private static let eyesWide: [Int: String] = [
        9: "..DGGDDWKKKWWKKKWDDGGD..",
        10: "..DGGWWKKKKWWKKKKWWGGD..",
        11: "...DGWWKKKKWWKKKKWWGD...",
    ]
    // 正面像没有尾巴可摇,「在忙」就靠五官整体左右挪一格来演 —— 像在罩子里东张西望。
    // 耳朵不跟着动:垂耳是搭在头两侧的,头在罩子里转一点,耳朵还挂在原处。
    private static let lookLeft: [Int: String] = [
        9: "..DGGDDKKWWWWKKWWDDGGD..",
        10: "..DGGWKWKKWWKWKKWWWGGD..",
        11: "...DGWWKKWWWWKKWWWWGD...",
        12: "...DGGWWWWKKWWWWWWGGD...",
        13: "....DGGWWKWWKWWWWGGD....",
    ]
    private static let lookRight: [Int: String] = [
        9: "..DGGDDWWKKWWWWKKDDGGD..",
        10: "..DGGWWWKWKKWWKWKKWGGD..",
        11: "...DGWWWWKKWWWWKKWWGD...",
        12: "...DGGWWWWWWKKWWWWGGD...",
        13: "....DGGWWWWKWWKWWGGD....",
    ]
    // 张嘴在鼻吻下面另开一行,不动鼻子 —— 鼻子和嘴挨着画会糊成一大坨黑,五官就没了。
    private static let mouthOpen: [Int: String] = [
        13: "....DGGWWWKKKKWWWGGD....",
        14: ".....DGGWWKTTKWWGGD.....",
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
