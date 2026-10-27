import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZAgent
import ZCore

/// ZAgent's `ImageResizer` with CoreGraphics + ImageIO: downscales screenshots for the model and crops them for the
/// computer tool's `zoom`. Output keeps the input format (PNG stays PNG, JPEG stays JPEG).
struct CoreGraphicsImageResizer: ImageResizer {
    var canResize: Bool { true }
    var canCrop: Bool { true }

    func resize(_ image: ImageData, to size: PixelSize) async throws -> ImageData {
        guard size.width > 0, size.height > 0 else {
            throw ZError.invalidArgument("resize target must be positive, got \(size.width)x\(size.height)")
        }
        let source = try Self.decode(image)
        if source.width == size.width, source.height == size.height {
            return ImageData(mime: image.mime, data: image.data, width: source.width, height: source.height)
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ZError.unsupported("cannot create a \(size.width)x\(size.height) bitmap context")
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw ZError.unsupported("cannot render the resized image") }
        return try Self.encode(scaled, like: image.mime)
    }

    func crop(_ image: ImageData, to rect: ScreenRect) async throws -> ImageData {
        let source = try Self.decode(image)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let wanted = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).intersection(bounds).integral
        guard !wanted.isNull, wanted.width >= 1, wanted.height >= 1, let cropped = source.cropping(to: wanted) else {
            throw ZError.invalidArgument("crop rectangle \(rect.x),\(rect.y) \(rect.width)x\(rect.height) is outside the "
                                         + "\(source.width)x\(source.height) image")
        }
        return try Self.encode(cropped, like: image.mime)
    }

    // MARK: Coding

    static func decode(_ image: ImageData) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ZError.decoding("the screenshot is not a readable image (\(image.mime), \(image.data.count) bytes)")
        }
        return decoded
    }

    static func encode(_ image: CGImage, like mime: String) throws -> ImageData {
        let jpeg = mime.lowercased() == "image/jpeg" || mime.lowercased() == "image/jpg"
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else {
            throw ZError.unsupported("cannot create an image encoder")
        }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ZError.unsupported("cannot encode the image") }
        return ImageData(mime: jpeg ? "image/jpeg" : "image/png", data: output as Data,
                         width: image.width, height: image.height)
    }

    static func pngData(_ image: CGImage) -> Data? {
        try? encode(image, like: "image/png").data
    }
}
