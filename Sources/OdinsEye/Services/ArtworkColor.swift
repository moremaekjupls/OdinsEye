import AppKit

/// Главный цвет обложки для фона вкладки «Музыка».
enum ArtworkColor {
    /// Картинка сжимается до 16×16, серые и почти чёрные или белые пиксели
    /// не считаются, остальные усредняются с весом по насыщенности. Нет
    /// заметного цвета (чёрно-белая обложка) возвращает nil: фон остаётся чёрным.
    static func dominant(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return dominant(ofRGBA: pixels)
    }

    static func dominant(ofRGBA pixels: [UInt8]) -> NSColor? {
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count - 3, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i]) / 255 / a
            let pg = Double(pixels[i + 1]) / 255 / a
            let pb = Double(pixels[i + 2]) / 255 / a
            let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
            guard hi > 0.15, lo < 0.9 else { continue }
            let saturation = hi == 0 ? 0 : (hi - lo) / hi
            let weight = saturation * saturation
            guard weight > 0.02 else { continue }
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0.5 else { return nil }
        return NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
    }
}
