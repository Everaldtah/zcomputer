import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class ScreenshotScalerTests: XCTestCase {
    func testScaleFactorAndSizes() {
        let s = ScreenshotScaler(maxLongEdge: 1366)
        XCTAssertEqual(s.scaleFactor(for: PixelSize(width: 2732, height: 1536)), 0.5)
        XCTAssertEqual(s.scaledSize(for: PixelSize(width: 2732, height: 1536)), PixelSize(width: 1366, height: 768))
        XCTAssertEqual(s.scaledSize(for: PixelSize(width: 1920, height: 1080)), PixelSize(width: 1366, height: 768))
        XCTAssertEqual(s.scaledSize(for: PixelSize(width: 1080, height: 1920)), PixelSize(width: 768, height: 1366))
        XCTAssertEqual(s.scaleFactor(for: PixelSize(width: 1024, height: 768)), 1)
        XCTAssertEqual(s.scaledSize(for: PixelSize(width: 1024, height: 768)), PixelSize(width: 1024, height: 768))
        XCTAssertEqual(ScreenshotScaler(maxLongEdge: 0).scaledSize(for: PixelSize(width: 5000, height: 100)), PixelSize(width: 5000, height: 100))
    }

    func testMappingBackToTheSurface() {
        let m = ScreenshotScaler().mapping(for: PixelSize(width: 2732, height: 1536))
        XCTAssertEqual(m.modelSize, PixelSize(width: 1366, height: 768))
        XCTAssertEqual(m.toSurface(x: 683, y: 384), ScreenPoint(x: 1366, y: 768))
        XCTAssertEqual(m.toSurface(x: 0, y: 0), ScreenPoint(x: 0, y: 0))
        XCTAssertEqual(m.toSurface(x: 5000, y: -10), ScreenPoint(x: 2731, y: 0), "clamped to the surface")
        XCTAssertEqual(m.toModel(x: 1366, y: 768), ScreenPoint(x: 683, y: 384))
        XCTAssertFalse(m.isIdentity)
        XCTAssertTrue(ScreenshotScaler().mapping(for: PixelSize(width: 2732, height: 1536), resizing: false).isIdentity)
        XCTAssertEqual(ScreenshotScaler.fit(PixelSize(width: 200, height: 100), into: PixelSize(width: 1366, height: 768)),
                       PixelSize(width: 1366, height: 683))
    }

    func testPrepareWithPassThroughKeepsCoordinatesExact() async throws {
        let image = ImageData(mime: "image/png", data: fakePNG(width: 2732, height: 1536))
        let (out, mapping) = try await ScreenshotScaler().prepare(image, surfaceSize: PixelSize(width: 2732, height: 1536),
                                                                  resizer: PassThroughImageResizer())
        XCTAssertEqual(out.width, 2732)
        XCTAssertTrue(mapping.isIdentity)
    }

    func testPrepareWithAResizerDownscalesAndMaps() async throws {
        let image = ImageData(mime: "image/png", data: fakePNG(width: 2732, height: 1536))
        let (out, mapping) = try await ScreenshotScaler().prepare(image, surfaceSize: PixelSize(width: 2732, height: 1536),
                                                                  resizer: FakeResizer())
        XCTAssertEqual(out.width, 1366)
        XCTAssertEqual(out.height, 768)
        XCTAssertEqual(mapping.scaleX, 2)
        XCTAssertEqual(mapping.scaleY, 2)
    }

    func testRetinaScreenshotOfAPointSizedSurfaceIsMappedFromTheImage() async throws {
        // 2x capture of a 1280x800 surface with no resizer: the model sees 2560x1600 pixels.
        let image = ImageData(mime: "image/png", data: fakePNG(width: 2560, height: 1600))
        let (_, mapping) = try await ScreenshotScaler(maxLongEdge: 2576).prepare(image, surfaceSize: PixelSize(width: 1280, height: 800),
                                                                                 resizer: PassThroughImageResizer())
        XCTAssertEqual(mapping.toSurface(x: 2000, y: 1000), ScreenPoint(x: 1000, y: 500))
    }

    func testImageHeaderParsing() {
        XCTAssertEqual(ImageHeader.size(of: fakePNG(width: 640, height: 480)), PixelSize(width: 640, height: 480))
        XCTAssertEqual(ImageHeader.mimeType(of: fakePNG(width: 1, height: 1)), "image/png")
        // Minimal JPEG: SOI, APP0 (len 16), SOF0 (len 17) with height 300, width 400.
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        jpeg += [UInt8](repeating: 0, count: 14)
        jpeg += [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x01, 0x90, 0x03]
        jpeg += [UInt8](repeating: 0, count: 9)
        XCTAssertEqual(ImageHeader.size(of: Data(jpeg)), PixelSize(width: 400, height: 300))
        XCTAssertEqual(ImageHeader.mimeType(of: Data(jpeg)), "image/jpeg")
        XCTAssertNil(ImageHeader.size(of: Data("not an image".utf8)))
    }
}
