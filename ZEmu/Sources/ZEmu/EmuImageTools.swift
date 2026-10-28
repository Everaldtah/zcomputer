import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ZCore

/// CoreGraphics helpers for screenshots (thread-safe; no UIKit/AppKit).
public enum EmuImageTools {
    /// Decodes PNG (or any ImageIO format) data.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// PNG encoding through ImageIO.
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw ZError.vm("cannot create a PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ZError.vm("PNG encoding failed") }
        return data as Data
    }

    /// Draws `image` into a small RGBA8 thumbnail and returns its bytes.
    static func thumbnailRGBA(_ image: CGImage, width: Int = 64, height: Int = 40) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when the image is a single flat colour (sampled on a 64x40 thumbnail).
    public static func isBlank(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0, let px = thumbnailRGBA(image) else { return true }
        return isUniform(rgba: px, width: 64, height: 40)
    }

    /// True when PNG data decodes to a flat colour (or does not decode).
    public static func isBlank(png: Data) -> Bool {
        guard let image = decode(png) else { return true }
        return isBlank(image)
    }

    /// True when every pixel of a tightly packed RGBA8 buffer has the same colour (alpha ignored).
    public static func isUniform(rgba: [UInt8], width: Int, height: Int, tolerance: Int = 0) -> Bool {
        let count = width * height
        guard count > 0, rgba.count >= count * 4 else { return true }
        let r0 = Int(rgba[0]), g0 = Int(rgba[1]), b0 = Int(rgba[2])
        var i = 4
        while i < count * 4 {
            if abs(Int(rgba[i]) - r0) > tolerance || abs(Int(rgba[i + 1]) - g0) > tolerance || abs(Int(rgba[i + 2]) - b0) > tolerance {
                return false
            }
            i += 4
        }
        return true
    }

    /// Renders VGA text-mode rows (light grey on black, 9x16 cells) into a PNG, for when the page cannot.
    public static func renderText(_ lines: [String], cols: Int = 80, cellWidth: Int = 9, cellHeight: Int = 16) throws -> ImageData {
        let rows = max(1, lines.count)
        let width = max(1, cols) * cellWidth
        let height = rows * cellHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ZError.vm("cannot create a text canvas")
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let colour = CGColor(srgbRed: 0.67, green: 0.67, blue: 0.67, alpha: 1)
        let attributes: [String: Any] = [kCTFontAttributeName as String: font,
                                         kCTForegroundColorAttributeName as String: colour]
        for (i, line) in lines.enumerated() {
            let trimmed = String(line.prefix(cols)).replacingOccurrences(of: "\u{0}", with: " ")
            guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty,
                  let attributed = CFAttributedStringCreate(nil, trimmed as CFString, attributes as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // Core Graphics' origin is bottom-left: row 0 is at the top.
            ctx.textPosition = CGPoint(x: 0, y: CGFloat(height - (i + 1) * cellHeight + 4))
            CTLineDraw(ctLine, ctx)
        }
        guard let image = ctx.makeImage() else { throw ZError.vm("cannot render text") }
        return ImageData(mime: "image/png", data: try pngData(image), width: width, height: height)
    }
}
