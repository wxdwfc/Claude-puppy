import AppKit
import SwiftUI

/// 磁盘皮肤:`~/.puppy/skins/<名字>/`。
///
///     skin.json          名字、格子边长、每个状态的 fps / 起伏 / 气泡
///     sleeping.png       横向帧条:宽 = 格子边长 × 帧数,高 = 格子边长
///     working.png
///     alert.png
///     celebrating.png
///
/// 帧条而不是一帧一个文件:一个状态的帧数是它自己的事,用宽度表达就不用在 json 里
/// 再报一遍帧数,也不会出现「json 说 4 帧、目录里只有 3 个文件」这种对不上的情况。
///
/// `puppy --export-skin <目录>` 会把内置皮卡丘按这个格式导出来,照着改最省事。
enum SkinLibrary {

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".puppy/skins", isDirectory: true)

    private static let defaultsKey = "PuppySkinID"

    /// 内置的永远排第一,磁盘皮肤按目录名跟在后面。
    /// 读不动的目录直接跳过 —— 皮肤是可选装饰,坏一个不该让整只宠物起不来。
    static func all() -> [MascotSkin] {
        var skins = [Sprites.builtIn]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            do {
                skins.append(try load(directory: url))
            } catch {
                FileHandle.standardError.write(
                    Data("皮肤 \(url.lastPathComponent) 读不了,跳过:\(error.localizedDescription)\n".utf8))
            }
        }
        return skins
    }

    /// 上次选的那套。皮肤目录可能已经被删了,所以必须能退回内置。
    static func saved() -> MascotSkin {
        guard let id = UserDefaults.standard.string(forKey: defaultsKey), id != Sprites.builtIn.id else {
            return Sprites.builtIn
        }
        return all().first { $0.id == id } ?? Sprites.builtIn
    }

    static func remember(_ skin: MascotSkin) {
        UserDefaults.standard.set(skin.id, forKey: defaultsKey)
    }

    // MARK: - 读

    enum SkinError: LocalizedError {
        case noManifest
        case badFrameStrip(state: String, width: Int, height: Int, cell: Int)
        case unreadableImage(state: String)

        var errorDescription: String? {
            switch self {
            case .noManifest:
                return "缺 skin.json"
            case let .badFrameStrip(state, width, height, cell):
                return "\(state).png 是 \(width)×\(height),但格子边长是 \(cell) —— 高必须正好等于格子边长,宽必须是它的整数倍"
            case let .unreadableImage(state):
                return "\(state).png 解不出来"
            }
        }
    }

    static func load(directory: URL) throws -> MascotSkin {
        let manifestURL = directory.appendingPathComponent("skin.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw SkinError.noManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let cell = manifest.cell

        var sprites: [MascotState: Sprite] = [:]
        for (key, spec) in manifest.states {
            guard let state = MascotState(rawValue: key) else { continue }
            let images = try frames(at: directory.appendingPathComponent("\(key).png"), cell: cell, state: key)
            sprites[state] = Sprite(
                images: images,
                fps: spec.fps ?? 4,
                // 没给起伏就一帧一个 0:帧数是图决定的,这里不能少给,少了会被循环取模复用错位。
                yOffsets: spec.yOffsets ?? Array(repeating: 0, count: max(images.count, 1)),
                bubble: spec.bubble,
                bubbleColor: spec.bubbleColor.flatMap(Color.init(hex:)) ?? .white
            )
        }

        return MascotSkin(
            id: directory.lastPathComponent,
            name: manifest.name ?? directory.lastPathComponent,
            side: cell,
            headRow: manifest.headRow ?? cell / 2,
            bubbleCells: manifest.bubbleCells.flatMap(range(from:)) ?? MascotSkin.defaultBubbleCells(side: cell),
            badgeCell: manifest.badgeCell ?? MascotSkin.defaultBadgeCell(side: cell),
            sprites: sprites
        )
    }

    private static func range(from pair: [Int]) -> ClosedRange<Int>? {
        guard pair.count == 2, pair[0] <= pair[1] else { return nil }
        return pair[0]...pair[1]
    }

    /// 帧条切片。走 CGImageSource 而不是 NSImage —— NSImage 会把 PNG 里的 DPI 元数据
    /// 算进 size 里,一张 96dpi 导出的图会报出非整数的尺寸,切片就会错位半格。
    private static func frames(at url: URL, cell: Int, state: String) throws -> [CGImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SkinError.unreadableImage(state: state) }

        let width = sheet.width, height = sheet.height
        guard height == cell, width > 0, width % cell == 0 else {
            throw SkinError.badFrameStrip(state: state, width: width, height: height, cell: cell)
        }
        return (0..<(width / cell)).compactMap {
            sheet.cropping(to: CGRect(x: $0 * cell, y: 0, width: cell, height: cell))
        }
    }

    // MARK: - skin.json

    private struct Manifest: Decodable {
        struct StateSpec: Decodable {
            var fps: Double?
            var yOffsets: [Double]?
            var bubble: String?
            var bubbleColor: String?
        }
        var name: String?
        var cell: Int
        var headRow: Int?
        var bubbleCells: [Int]?
        var badgeCell: Int?
        var states: [String: StateSpec]
    }
}

extension Color {
    /// `#rrggbb`。皮肤是手写 json,给个最眼熟的写法。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
