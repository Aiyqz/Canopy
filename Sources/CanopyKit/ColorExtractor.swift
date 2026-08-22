// ColorExtractor.swift —— 从专辑封面提取渐变色板（类 Apple Music 风格）。
import AppKit
import SwiftUI

/// Extracts a small palette of dominant colors from album art to build
/// Apple-Music-style gradient backgrounds.
enum ColorExtractor {
    static let fallback: [Color] = [
        Color(red: 0.22, green: 0.24, blue: 0.32),
        Color(red: 0.10, green: 0.11, blue: 0.18)
    ]

    static func palette(from image: NSImage?, count: Int = 4) -> [Color] {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return fallback }

        let dim = 24
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: dim, height: dim,
            bitsPerComponent: 8, bytesPerRow: dim * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return fallback }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        // Quantize into coarse buckets, weight by saturation so vivid colors win.
        struct Bucket { var r = 0.0; var g = 0.0; var b = 0.0; var w = 0.0 }
        var buckets: [Int: Bucket] = [:]

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            let maxc = max(r, g, b), minc = min(r, g, b)
            let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
            // Down-weight near-black & near-white so backgrounds don't dominate.
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let weight = (0.25 + sat) * (lum > 0.05 && lum < 0.97 ? 1 : 0.25)

            let key = (Int(r * 5) << 8) | (Int(g * 5) << 4) | Int(b * 5)
            var bkt = buckets[key] ?? Bucket()
            bkt.r += r * weight; bkt.g += g * weight; bkt.b += b * weight; bkt.w += weight
            buckets[key] = bkt
        }

        let sorted = buckets.values.filter { $0.w > 0 }.sorted { $0.w > $1.w }
        guard !sorted.isEmpty else { return fallback }

        let colors = sorted.prefix(count).map { bkt -> Color in
            let c = NSColor(
                red: bkt.r / bkt.w, green: bkt.g / bkt.w, blue: bkt.b / bkt.w, alpha: 1
            )
            // Nudge saturation/brightness for the rich Apple Music feel.
            let boosted = c.usingColorSpace(.deviceRGB)?.withSaturation(by: 1.12, brightness: 0.95) ?? c
            return Color(boosted)
        }
        return colors.count >= 2 ? colors : (colors + fallback)
    }
}

private extension NSColor {
    func withSaturation(by satMul: CGFloat, brightness brightMul: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * satMul, 1), brightness: min(b * brightMul, 1), alpha: a)
    }
}
