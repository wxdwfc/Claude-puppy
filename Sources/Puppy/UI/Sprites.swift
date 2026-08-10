import SwiftUI

/// 内置皮肤:程序化像素皮卡丘。每帧是 32×32 的字符位图,字符查调色板。
///
/// 造型走 chibi 比例 —— 「圆鼓鼓」不是把某一块画胖,是整套比例一起换:
/// 脑袋 19 宽 × 15 高、占身高一半且横着比竖着宽;身子 17 宽 × 5 高,宽度追到脑袋的九成
/// (差得多就有脖子,有脖子就不是玩偶);腿收成 3 行小短脚。第一版是 13 行脑袋配 7 行身子
/// 加两条长腿,比例上是「站着的老鼠」,怎么调五官都不会可爱。
///
/// 辨识度全靠三个互相独立的色块信号:黑尖长耳、红脸蛋、右边那条闪电尾 ——
/// 任何一个单独出现都认得出来。这也正是它比上一版白狗更适合这个尺寸的原因:
/// 白狗的可读性靠白毛/浅灰耳/蓝玻璃之间的明暗差,而低分辨率下最先糊掉的就是明暗。
///
/// 想换形象不用改这个文件 —— 往 `~/.puppy/skins/` 里丢一套 PNG 就行,见 `SkinLibrary`。
enum Palette {
    /// 字符 → RGB。表里没有的字符('.')= 完全透明。
    static let rgb: [Character: (UInt8, UInt8, UInt8)] = [
        "K": (28, 24, 20),      // 描边 / 眼睛 / 耳尖 / 嘴
        "Y": (252, 206, 62),    // 皮卡丘黄
        "O": (226, 158, 26),    // 黄的暗部:肚子下沿和脚面
        "R": (232, 66, 60),     // 脸蛋红
        "r": (255, 92, 62),     // 脸蛋放电时的亮红 —— 只提亮度不掉饱和,掉了就成粉的
        "W": (255, 255, 255),   // 眼里的反光
        "B": (156, 96, 32),     // 尾巴根的褐色
        "T": (236, 118, 130),   // 舌头
    ]
}

/// 字符位图 → RGBA 图。放大交给 `.interpolation(.none)`,像素边缘保持硬朗。
enum PixelRaster {
    static func image(from rows: [String], side: Int) -> CGImage? {
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
        return image(fromRGBA: bytes, width: side, height: side)
    }

    static func image(fromRGBA bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

enum Sprites {
    static let side = 32
    /// 眼睛所在的行。气泡尾巴对着这一行,才是「对着脸说话」而不是对着肚子。
    static let headRow = 16
    /// 两只耳朵中间那段空地 —— 状态气泡摊在这儿。
    static let bubbleCells = 7...17
    /// 右耳外侧、闪电尾上方的空档。
    static let badgeCell = 25

    // 整只角色共用 x=12 这一根对称轴 —— 每一行的左右端点相加都等于 24。
    // 最早那版脑袋用的是偶数宽(中心落在 12.5),耳朵和身体是奇数宽(中心 13),
    // 差的这半格会把五官整体推向一侧,正面看就是张歪脸。
    //
    // 轮廓不是一格一格手抠的,是 scripts/gen-sprites.py 按「行区间 + 自动描边」算出来的。
    // 要改造型去改那个脚本再贴回来 —— 描边、五官裁剪、左右对称在那边是自动保证的。
    //
    // 布局:y0-y10 耳朵,y9-y23 脑袋,y24-y28 身子,y29-y31 小短脚,右边 y14-y28 闪电尾。
    //
    // 五官分两层排,不并排:脑袋只有 19 格宽,眼睛(5+5)+ 中缝 + 脸蛋(4+4)横着摆不下。
    // 眼睛在上(y14-y18)、脸蛋在下且更靠外(y19-y22),纵向完全错开 —— 这也正好是
    // 真皮卡丘的关系。
    //
    // 眼睛 5×5 并且压在脑袋下半部:大脑门 + 低眼位 + 大眼睛是最讨喜的三件套,
    // 少哪件都会显得「精明」而不是「憨」。反光给到 2×2,一格的反光在 5×5 的眼睛里
    // 读不出「亮」,只像脏了一点。
    //
    // 鼻子只给一格。给到 3 格宽,它和下面的嘴会连成一整块黑,读成一个吻部,五官就没了。
    //
    // 耳朵 11 行、7 格宽、明显往外斜,顶上那行收成 3 格。9 行的短耳朵读成两只猫耳;
    // 拉平 5 格顶到 y0 的话,耳朵读成两根从画布上沿伸进来的黑棍子。
    // 耳尖整块涂黑 5 行 —— 这是「是皮卡丘」最强的一个信号,少一行都发虚。
    //
    // 手臂只在身子里画一段向外弯的弧,不去顶轮廓。在轮廓上鼓两个小包的话,一来右边
    // 留给闪电尾的通道只剩一格、鼓包一出来就和尾巴连上了,二来「圆鼓鼓」要的就是
    // 一条干净的圆边,鼓包正好反着来。

    private static let base: [String] = [
        "..KKK...............KKK.........",
        ".KKKKK.............KKKKK........",
        ".KKKKK.............KKKKK........",
        ".KKKKKK...........KKKKKK........",
        ".KKKKKK...........KKKKKK........",
        "..KYYYYK.........KYYYYK.........",
        "..KYYYYK.........KYYYYK.........",
        "...KYYYYK.......KYYYYK..........",
        "...KYYYYK.......KYYYYK..........",
        "....KYYYYKKKKKKKYYYYK...........",
        "....KYYYYYYYYYYYYYYYK...........",
        "....KYYYYYYYYYYYYYYYK...........",
        "...KYYYYYYYYYYYYYYYYYK..........",
        "...KYYYYYYYYYYYYYYYYYK..........",
        "...KYYKKKYYYYYYYKKKYYK.....KKKKK",
        "...KYKWWKKYYYYYKWWKKYK.....KYYYK",
        "...KYKWKKKYYYYYKWKKKYK...KKYYYYK",
        "...KYKKKKKYYYYYKKKKKYK...KYYYYYK",
        "...KYYKKKYYYYYYYKKKYYK.KKYYYYYYK",
        "...KYYRRYYYYKYYYYRRYYK.KYYYYYYKK",
        "....KRRRRYYYYYYYRRRRK..KYYYYYK..",
        ".....RRRRKYYKYYKRRRR...KYYYYK...",
        "......RRYYKKYKKYYRR....KYYYK....",
        "........KYYYYYYYK......KYYYK....",
        ".....KKKYYYYYYYYYKKK..KYYYK.....",
        "....KYKYYYYYYYYYYYKYK.KYYYK.....",
        "....KYKYYYYYYYYYYYKYK.KYYKK.....",
        "....KKOKOOOOOOOOOKOOBKBKK.......",
        "......KOOOOKKKOOOOBBKKK.........",
        ".....KYYYYK...KYYYYK............",
        ".....KOOOOK...KOOOOK............",
        "......KKKK.....KKKK.............",
    ]
    /// 闭眼。
    private static let closed: [Int: String] = [
        14: "...KYYYYYYYYYYYYYYYYYK.....KKKKK",
        15: "...KYYYYYYYYYYYYYYYYYK.....KYYYK",
        16: "...KYKYYYKYYYYYKYYYKYK...KKYYYYK",
        18: "...KYYYYYYYYYYYYYYYYYK.KKYYYYYYK",
    ]
    /// 笑成 `^ ^`。5 格宽的眼睛能画出真正的尖角,不再是两道折线。
    private static let happy: [Int: String] = [
        14: "...KYYYYYYYYYYYYYYYYYK.....KKKKK",
        15: "...KYYYKYYYYYYYYYKYYYK.....KYYYK",
        16: "...KYYKYKYYYYYYYKYKYYK...KKYYYYK",
        17: "...KYKYYYKYYYYYKYYYKYK...KYYYYYK",
        18: "...KYYYYYYYYYYYYYYYYYK.KKYYYYYYK",
    ]
    /// 瞪眼:吃掉反光 + 往下长一格。
    /// 只往下长,而且上沿的角照旧削掉 —— 眼睛左右各只离脑袋的描边一格,
    /// 一旦把角补满,眼珠就和侧脸的描边连成一条横杠,远看是「戴了个眼罩」而不是瞪眼。
    private static let wide: [Int: String] = [
        14: "...KYYKKYYYYYYYYKKYYYK.....KKKKK",
        15: "...KYKKKKKYYYYYKKKKKYK.....KYYYK",
        16: "...KYKKKKKYYYYYKKKKKYK...KKYYYYK",
        18: "...KYKKKKKYYYYYKKKKKYK.KKYYYYYYK",
        19: "...KYKKKKKYYKYYKKKKKYK.KYYYYYYKK",
    ]
    /// 正面像没有尾巴可摇,「在忙」就靠五官(眼睛 + 鼻子 + 嘴)整体挪一格来演。
    /// 耳朵和脸蛋不跟着动:头只是转了一点,长在两侧的东西还在原处。
    private static let lookLeft: [Int: String] = [
        14: "...KYKKKYYYYYYYKKKYYYK.....KKKKK",
        15: "...KKWWKKYYYYYKWWKKYYK.....KYYYK",
        16: "...KKWKKKYYYYYKWKKKYYK...KKYYYYK",
        17: "...KKKKKKYYYYYKKKKKYYK...KYYYYYK",
        18: "...KYKKKYYYYYYYKKKYYYK.KKYYYYYYK",
        19: "...KYYRRYYYKYYYYYRRYYK.KYYYYYYKK",
        21: ".....RRRKYYKYYKYRRRR...KYYYYK...",
        22: "......RRYKKYKKYYYRR....KYYYK....",
    ]
    private static let lookRight: [Int: String] = [
        14: "...KYYYKKKYYYYYYYKKKYK.....KKKKK",
        15: "...KYYKWWKKYYYYYKWWKKK.....KYYYK",
        16: "...KYYKWKKKYYYYYKWKKKK...KKYYYYK",
        17: "...KYYKKKKKYYYYYKKKKKK...KYYYYYK",
        18: "...KYYYKKKYYYYYYYKKKYK.KKYYYYYYK",
        19: "...KYYRRYYYYYKYYYRRYYK.KYYYYYYKK",
        21: ".....RRRRYKYYKYYKRRR...KYYYYK...",
        22: "......RRYYYKKYKKYRR....KYYYK....",
    ]
    /// 张嘴吐舌。在鼻子下面另开一块,不动鼻子 —— 挨着画会糊成一坨黑。
    private static let open: [Int: String] = [
        20: "....KRRRRYKKKKKYRRRRK..KYYYYYK..",
        21: ".....RRRRKKKKKKKRRRR...KYYYYK...",
        22: "......RRYKKTTTKKYRR....KYYYK....",
        23: "........KYKKKKKYK......KYYYK....",
    ]
    /// 张嘴 + 笑眼,celebrating 的主帧。
    private static let openHappy: [Int: String] = [
        14: "...KYYYYYYYYYYYYYYYYYK.....KKKKK",
        15: "...KYYYKYYYYYYYYYKYYYK.....KYYYK",
        16: "...KYYKYKYYYYYYYKYKYYK...KKYYYYK",
        17: "...KYKYYYKYYYYYKYYYKYK...KYYYYYK",
        18: "...KYYYYYYYYYYYYYYYYYK.KKYYYYYYK",
        20: "....KRRRRYKKKKKYRRRRK..KYYYYYK..",
        21: ".....RRRRKKKKKKKRRRR...KYYYYK...",
        22: "......RRYKKTTTKKYRR....KYYYK....",
        23: "........KYKKKKKYK......KYYYK....",
    ]
    /// 脸蛋放电:瞪眼 + 脸蛋涨大一圈并提亮。和 wide 交替播放就是「噼啪闪」,
    /// 这是皮卡丘白送的一套状态语言 —— 上一版白狗只能靠眼睛大小硬撑。
    private static let spark: [Int: String] = [
        14: "...KYYKKYYYYYYYYKKYYYK.....KKKKK",
        15: "...KYKKKKKYYYYYKKKKKYK.....KYYYK",
        16: "...KYKKKKKYYYYYKKKKKYK...KKYYYYK",
        18: "...KYKKKKKYYYYYKKKKKYK.KKYYYYYYK",
        19: "...KrKKKKKYYKYYKKKKKrK.KYYYYYYKK",
        20: "....rrrrrYYYYYYYrrrrr..KYYYYYK..",
        21: ".....rrrrKYYKYYKrrrr...KYYYYK...",
        22: "......rrYYKKYKKYYrr....KYYYK....",
    ]
    private static func pose(_ patches: [Int: String]...) -> [String] {
        var rows = base
        for patch in patches {
            for (index, row) in patch { rows[index] = row }
        }
        return rows
    }

    private static func sprite(_ frames: [[String]], fps: Double, yOffsets: [Double],
                               bubble: String? = nil, bubbleColor: Color = .clear) -> Sprite {
        Sprite(images: frames.compactMap { PixelRaster.image(from: $0, side: side) },
               fps: fps, yOffsets: yOffsets, bubble: bubble, bubbleColor: bubbleColor)
    }

    // MARK: - 每个状态一组帧
    //
    // 每个姿势都是一整套「已经调好的行」,直接盖在 base 上,不做姿势之间的叠加 ——
    // 脸蛋和嘴共用 y19-y22,张嘴和放电两个补丁一旦叠在同一帧上就会互相吃掉。
    //
    // 起伏一律走 yOffsets,不去动帧位图 —— 位图整行平移会把最下面一行挤出画布,
    // 而脚一直画到 y31。offset 一律取整格(一格 = 3pt),半格会让放大后的像素行
    // 一会儿 3pt 一会儿 4pt,边缘就毛了。

    /// 完成提示的绿色。徽标和 celebrating 的气泡共用,免得两处调色调歪。
    static let doneColor = Color(red: 0.30, green: 0.78, blue: 0.45)
    /// 「有人在等你」的红。
    static let alertColor = Color(red: 0.95, green: 0.35, blue: 0.30)

    static let builtIn = MascotSkin(
        id: "builtin",
        name: "皮卡丘(内置)",
        side: side,
        headRow: headRow,
        bubbleCells: bubbleCells,
        badgeCell: badgeCell,
        sprites: [
            // 全空闲:闭眼 + 呼吸起伏 + 飘 z。
            .sleeping: sprite([pose(closed), pose(closed)],
                              fps: 1, yOffsets: [0, 1],
                              bubble: "z", bubbleColor: Color(white: 0.65)),

            // 有 session 在跑:左顾右盼 + 轻微起伏。
            .working: sprite([pose(lookLeft), pose(), pose(lookRight), pose()],
                             fps: 5, yOffsets: [-1, 0, -1, 0]),

            // 有 session 在等用户:瞪眼 + 脸蛋噼啪闪 + 上下跳 + "!"。最高优先级,要最扎眼。
            // 气泡没换成 ⚡:那个码位在 macOS 上按 emoji 上色,吃不到 bubbleColor,
            // 一整排状态气泡里就它一个不听配色。红色的 "!" 才是最急的那一档,
            // 「皮卡丘感」交给闪的脸蛋去演。
            .alert: sprite([pose(spark), pose(wide)],
                           fps: 4, yOffsets: [-2, 1],
                           bubble: "!", bubbleColor: alertColor),

            // 刚完成:张嘴吐舌 + 笑成一对 `^ ^` + 蹦跶 + "✓"。
            // 画布上下各只有 8pt 余量(112 窗口 / 96 画布),3pt 一格 —— 跳到 -2 还剩 2pt。
            .celebrating: sprite([pose(openHappy), pose(open)],
                                 fps: 6, yOffsets: [-2, 0],
                                 bubble: "✓", bubbleColor: doneColor),
        ]
    )
}
