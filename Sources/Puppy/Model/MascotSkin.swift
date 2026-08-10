import SwiftUI

/// 一个状态的整套帧 + 头顶气泡。
///
/// 图在构造时就烤成了 CGImage,播放时每一帧只是一次缩放 blit ——
/// 这一点对内置皮肤(字符位图现画)和磁盘皮肤(PNG 现切)是一样的,
/// 所以视图完全不需要知道图是哪儿来的。
struct Sprite {
    let images: [CGImage]
    let fps: Double
    /// 与帧一一对应的纵向偏移,单位是**格**不是点 —— 换算要用 `MascotSkin.side`。
    let yOffsets: [Double]
    /// 头顶气泡,nil = 不画。
    let bubble: String?
    let bubbleColor: Color

    var frameCount: Int { max(images.count, 1) }

    func image(at index: Int) -> CGImage? {
        images.isEmpty ? nil : images[index % images.count]
    }

    func yOffset(at index: Int) -> Double {
        yOffsets.isEmpty ? 0 : yOffsets[index % yOffsets.count]
    }
}

/// 一整套形象。内置的皮卡丘和用户丢进 `~/.puppy/skins/` 的目录是同一个类型 ——
/// 视图只认这个,不关心图是编在二进制里还是刚从磁盘读上来的。
///
/// 尺寸和几个锚点都跟着皮肤走,不写死:换一套 48 格的美术,起伏的幅度、
/// 气泡对准的高度会自己跟上,不用回来改视图。
struct MascotSkin: Identifiable, Equatable {
    /// 内置的是 "builtin",磁盘皮肤用目录名。也是持久化时存的那个值。
    let id: String
    /// 菜单里显示的名字。
    let name: String
    /// 一格 sprite 的像素边长。
    let side: Int
    /// 气泡尾巴对准的行(格)。指向眼睛那一行,才是「对着脸说话」而不是对着肚子。
    let headRow: Int
    /// 状态气泡占的横向格区间。挑一段头顶上空着的地方 —— 皮卡丘就是两只耳朵中间。
    let bubbleCells: ClosedRange<Int>
    /// ✓ 徽标落点的横向格坐标。要和气泡分开,两个同时出现时才不打架。
    let badgeCell: Int
    let sprites: [MascotState: Sprite]

    static func == (lhs: MascotSkin, rhs: MascotSkin) -> Bool { lhs.id == rhs.id }

    /// 缺哪个状态就退回 sleeping;连 sleeping 都没有就画个空的。
    /// 皮肤是用户随手丢进来的,缺一个状态不该让整只宠物崩掉。
    func sprite(for state: MascotState) -> Sprite {
        sprites[state] ?? sprites[.sleeping] ?? Self.blank
    }

    private static let blank = Sprite(images: [], fps: 1, yOffsets: [0], bubble: nil, bubbleColor: .clear)

    /// 没写锚点时的默认值:气泡摊在头顶中段,徽标靠右上角。
    static func defaultBubbleCells(side: Int) -> ClosedRange<Int> { (side / 5)...(side * 3 / 5) }
    static func defaultBadgeCell(side: Int) -> Int { side * 27 / 32 }
}
