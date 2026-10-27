import CoreGraphics
import Foundation
import ImageIO
import ZCore

/// Pixel checks used to detect blank captures (view not yet drawn, wrong backing size, guest DPMS blanking).
public enum PixelAnalysis {
    /// True when every pixel of a tightly packed RGBA8 buffer has the same colour (within `tolerance` per
    /// channel, alpha ignored). An empty buffer counts as blank.
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

    /// True when the buffer is uniformly (near) black.
    public static func isBlack(rgba: [UInt8], width: Int, height: Int, threshold: Int = 8) -> Bool {
        let count = width * height
        guard count > 0, rgba.count >= count * 4 else { return true }
        var i = 0
        while i < count * 4 {
            if Int(rgba[i]) > threshold || Int(rgba[i + 1]) > threshold || Int(rgba[i + 2]) > threshold { return false }
            i += 4
        }
        return true
    }
}

/// CoreGraphics helpers (thread-safe; no AppKit).
public enum ImageTools {
    /// Draws `image` into a small RGBA8 thumbnail (premultiplied, sRGB) and returns its bytes.
    public static func thumbnailRGBA(_ image: CGImage, width: Int = 64, height: Int = 40) -> [UInt8]? {
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

    /// True when the capture is a single flat colour (zyvor's blank test on a 64×40 sample).
    public static func isBlank(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0, let px = thumbnailRGBA(image) else { return true }
        return PixelAnalysis.isUniform(rgba: px, width: 64, height: 40)
    }

    /// Makes an opaque RGBA image from raw bytes (tests and synthetic frames).
    public static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba.prefix(width * height * 4)) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Scales `image` to exactly `width`×`height` pixels (no-op when it already has that size).
    public static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard width > 0, height > 0, image.width != width || image.height != height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
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

    /// Pixel size of PNG data (reads the IHDR chunk).
    public static func pngSize(_ data: Data) -> PixelSize? {
        guard data.count >= 24, Bytes.u32be(data, 0) == 0x8950_4E47, Bytes.u32be(data, 12) == 0x4948_4452 else { return nil }
        return PixelSize(width: Int(Bytes.u32be(data, 16)), height: Int(Bytes.u32be(data, 20)))
    }
}
