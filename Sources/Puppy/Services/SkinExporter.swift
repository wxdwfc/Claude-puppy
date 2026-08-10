import AppKit
import SwiftUI

/// 把一套皮肤按 `SkinLibrary` 认的格式写到磁盘。
///
/// 存在的理由只有一个:让「自己做一套皮肤」有个能跑的起点。
/// 光有格式文档不够 —— 帧条要多宽、yOffsets 要给几个、气泡该挂在哪一格,
/// 照着一份导出来的真皮肤改,比对着文档猜快得多。
enum SkinExporter {

    static func export(_ skin: MascotSkin, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var states: [String: [String: Any]] = [:]
        for (state, sprite) in skin.sprites {
            guard !sprite.images.isEmpty else { continue }
            try writeStrip(sprite.images, side: skin.side,
                           to: directory.appendingPathComponent("\(state.rawValue).png"))
            var spec: [String: Any] = ["fps": sprite.fps, "yOffsets": sprite.yOffsets]
            if let bubble = sprite.bubble {
                spec["bubble"] = bubble
                spec["bubbleColor"] = hex(of: sprite.bubbleColor)
            }
            states[state.rawValue] = spec
        }

        let manifest: [String: Any] = [
            "name": "\(skin.name) 的副本",
            "cell": skin.side,
            "headRow": skin.headRow,
            "bubbleCells": [skin.bubbleCells.lowerBound, skin.bubbleCells.upperBound],
            "badgeCell": skin.badgeCell,
            "states": states,
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: directory.appendingPathComponent("skin.json"))
    }

    /// 帧横着拼成一条。宽 = 边长 × 帧数,高 = 边长 —— 读回来时靠宽度反推帧数。
    private static func writeStrip(_ frames: [CGImage], side: Int, to url: URL) throws {
        let width = side * frames.count
        guard let context = CGContext(
            data: nil, width: width, height: side,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }

        context.interpolationQuality = .none
        for (index, frame) in frames.enumerated() {
            context.draw(frame, in: CGRect(x: index * side, y: 0, width: side, height: side))
        }
        guard let sheet = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }

        let rep = NSBitmapImageRep(cgImage: sheet)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    private static func hex(of color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
