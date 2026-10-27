import Foundation
import ZCore

/// A point in some pixel space.
public struct ScreenPoint: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// A rectangle in some pixel space.
public struct ScreenRect: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Maps between the model's screenshot space and the surface's own pixel space.
public struct CoordinateMapping: Hashable, Sendable, Codable {
    /// The surface's coordinate space (`ComputerSurface.displaySize`).
    public var surfaceSize: PixelSize
    /// The size of the screenshots the model sees.
    public var modelSize: PixelSize

    public init(surfaceSize: PixelSize, modelSize: PixelSize) {
        self.surfaceSize = surfaceSize; self.modelSize = modelSize
    }

    public static func identity(_ size: PixelSize) -> CoordinateMapping { .init(surfaceSize: size, modelSize: size) }

    /// Multiplier from model x to surface x.
    public var scaleX: Double { modelSize.width > 0 ? Double(surfaceSize.width) / Double(modelSize.width) : 1 }
    /// Multiplier from model y to surface y.
    public var scaleY: Double { modelSize.height > 0 ? Double(surfaceSize.height) / Double(modelSize.height) : 1 }
    public var isIdentity: Bool { surfaceSize == modelSize }

    /// Model coordinates → surface coordinates, clamped to the surface.
    public func toSurface(x: Int, y: Int) -> ScreenPoint {
        ScreenPoint(x: Self.clamp(Int((Double(x) * scaleX).rounded()), surfaceSize.width),
                    y: Self.clamp(Int((Double(y) * scaleY).rounded()), surfaceSize.height))
    }

    /// Surface coordinates → model coordinates, clamped to the model image.
    public func toModel(x: Int, y: Int) -> ScreenPoint {
        let sx = scaleX, sy = scaleY
        return ScreenPoint(x: Self.clamp(Int((Double(x) / (sx > 0 ? sx : 1)).rounded()), modelSize.width),
                           y: Self.clamp(Int((Double(y) / (sy > 0 ? sy : 1)).rounded()), modelSize.height))
    }

    /// Scales a distance (e.g. a scroll offset) from model space to surface space.
    public func scaleDistance(dx: Int, dy: Int) -> (dx: Int, dy: Int) {
        (Int((Double(dx) * scaleX).rounded()), Int((Double(dy) * scaleY).rounded()))
    }

    private static func clamp(_ v: Int, _ size: Int) -> Int {
        guard size > 0 else { return max(0, v) }
        return min(max(0, v), size - 1)
    }
}

/// Resizes (and optionally crops) images. The app implements this with CoreGraphics / ImageIO; on Linux and in
/// tests the pass-through default leaves images untouched (and coordinates are then not rescaled).
public protocol ImageResizer: Sendable {
    /// False for resizers that cannot change pixel dimensions; the scaler then keeps a 1:1 mapping.
    var canResize: Bool { get }
    /// Returns the image scaled to `size` (width/height should be set on the result).
    func resize(_ image: ImageData, to size: PixelSize) async throws -> ImageData
    /// True when `crop` works (enables the computer tool's `zoom`). Default false.
    var canCrop: Bool { get }
    /// Returns the `rect` part of the image (in the image's own pixels). Default: throws `ZError.unsupported`.
    func crop(_ image: ImageData, to rect: ScreenRect) async throws -> ImageData
}

public extension ImageResizer {
    var canCrop: Bool { false }
    func crop(_ image: ImageData, to rect: ScreenRect) async throws -> ImageData { throw ZError.unsupported("image cropping") }
}

/// Leaves images as they are.
public struct PassThroughImageResizer: ImageResizer {
    public init() {}
    public var canResize: Bool { false }
    public func resize(_ image: ImageData, to size: PixelSize) async throws -> ImageData { image }
}

/// Downscales screenshots to a maximum long edge for the model and maps the model's coordinates back.
/// Pure arithmetic; pixel work is delegated to an `ImageResizer`.
public struct ScreenshotScaler: Hashable, Sendable, Codable {
    public static let defaultMaxLongEdge = 1366

    /// Longest side of the image the model sees. 0 or less disables scaling.
    public var maxLongEdge: Int

    public init(maxLongEdge: Int = ScreenshotScaler.defaultMaxLongEdge) { self.maxLongEdge = maxLongEdge }

    /// Factor (≤ 1) that brings `size` within `maxLongEdge`.
    public func scaleFactor(for size: PixelSize) -> Double {
        let longEdge = max(size.width, size.height)
        guard maxLongEdge > 0, longEdge > maxLongEdge else { return 1 }
        return Double(maxLongEdge) / Double(longEdge)
    }

    /// The size the model sees for a surface of `size`.
    public func scaledSize(for size: PixelSize) -> PixelSize {
        let f = scaleFactor(for: size)
        guard f < 1 else { return size }
        let longIsWidth = size.width >= size.height
        let w = longIsWidth ? maxLongEdge : max(1, Int((Double(size.width) * f).rounded()))
        let h = longIsWidth ? max(1, Int((Double(size.height) * f).rounded())) : maxLongEdge
        return PixelSize(width: w, height: h)
    }

    /// The largest size with `size`'s aspect ratio that fits in `bounds`.
    public static func fit(_ size: PixelSize, into bounds: PixelSize) -> PixelSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let f = min(Double(bounds.width) / Double(size.width), Double(bounds.height) / Double(size.height))
        return PixelSize(width: max(1, Int((Double(size.width) * f).rounded())), height: max(1, Int((Double(size.height) * f).rounded())))
    }

    /// The mapping the model will be working in. Pass `resizing: false` when no real resizer is available.
    public func mapping(for surfaceSize: PixelSize, resizing: Bool = true) -> CoordinateMapping {
        resizing ? CoordinateMapping(surfaceSize: surfaceSize, modelSize: scaledSize(for: surfaceSize)) : .identity(surfaceSize)
    }

    /// Scales a screenshot for the model and returns the mapping that matches the image actually produced.
    public func prepare(_ image: ImageData, surfaceSize: PixelSize,
                        resizer: any ImageResizer) async throws -> (image: ImageData, mapping: CoordinateMapping) {
        var img = image.withDetectedSize()
        let target = scaledSize(for: surfaceSize)
        let current = PixelSize(width: img.width ?? surfaceSize.width, height: img.height ?? surfaceSize.height)
        if resizer.canResize, current != target {
            img = try await resizer.resize(img, to: target).withDetectedSize()
            if img.width == nil || img.height == nil {
                img.width = img.width ?? target.width
                img.height = img.height ?? target.height
            }
        }
        let modelSize = PixelSize(width: img.width ?? surfaceSize.width, height: img.height ?? surfaceSize.height)
        return (img, CoordinateMapping(surfaceSize: surfaceSize, modelSize: modelSize))
    }
}

// MARK: - Image header parsing

/// Reads pixel dimensions and type from PNG / JPEG headers (no decoding).
public enum ImageHeader {
    public static func mimeType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    public static func size(of data: Data) -> PixelSize? {
        let bytes = [UInt8](data.prefix(256 * 1024))
        return pngSize(bytes) ?? jpegSize(bytes)
    }

    static func pngSize(_ b: [UInt8]) -> PixelSize? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 24, Array(b[0..<8]) == signature,
              b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else { return nil }  // "IHDR"
        let w = be32(b, 16), h = be32(b, 20)
        guard w > 0, h > 0 else { return nil }
        return PixelSize(width: w, height: h)
    }

    static func jpegSize(_ b: [UInt8]) -> PixelSize? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }  // no length
            if marker == 0xD9 || marker == 0xDA { return nil }           // end of image / start of scan
            let length = be16(b, i + 2)
            guard length >= 2 else { return nil }
            let isSOF = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF {
                guard i + 8 < b.count else { return nil }
                let h = be16(b, i + 5), w = be16(b, i + 7)
                guard w > 0, h > 0 else { return nil }
                return PixelSize(width: w, height: h)
            }
            i += 2 + length
        }
        return nil
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 1 < b.count else { return 0 }
        return Int(b[i]) << 8 | Int(b[i + 1])
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 3 < b.count else { return 0 }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}

extension ImageData {
    /// Fills in width/height from the header when they are missing.
    func withDetectedSize() -> ImageData {
        guard width == nil || height == nil, let s = ImageHeader.size(of: data) else { return self }
        var copy = self
        copy.width = width ?? s.width
        copy.height = height ?? s.height
        return copy
    }
}
