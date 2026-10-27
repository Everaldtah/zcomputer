import CoreGraphics
import Foundation
import XCTest
import ZCore
@testable import ZVM

final class ImageTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i + 1] = g; px[i + 2] = b }
        return px
    }

    func testUniformBuffersAreBlank() {
        XCTAssertTrue(PixelAnalysis.isUniform(rgba: solid(8, 4, 0, 0, 0), width: 8, height: 4))
        XCTAssertTrue(PixelAnalysis.isUniform(rgba: solid(8, 4, 40, 90, 200), width: 8, height: 4))
        XCTAssertTrue(PixelAnalysis.isUniform(rgba: [], width: 0, height: 0))
        XCTAssertTrue(PixelAnalysis.isBlack(rgba: solid(4, 4, 3, 2, 1), width: 4, height: 4))
        XCTAssertFalse(PixelAnalysis.isBlack(rgba: solid(4, 4, 30, 2, 1), width: 4, height: 4))
    }

    func testOneDifferentPixelIsNotBlank() {
        var px = solid(8, 4, 0, 0, 0)
        px[4 * 13] = 255
        XCTAssertFalse(PixelAnalysis.isUniform(rgba: px, width: 8, height: 4))
        // Within tolerance it still counts as uniform.
        px[4 * 13] = 3
        XCTAssertTrue(PixelAnalysis.isUniform(rgba: px, width: 8, height: 4, tolerance: 4))
        XCTAssertFalse(PixelAnalysis.isUniform(rgba: px, width: 8, height: 4, tolerance: 2))
    }

    func testBlankDetectionOnCGImages() throws {
        let black = try XCTUnwrap(ImageTools.makeImage(rgba: solid(320, 200, 0, 0, 0), width: 320, height: 200))
        XCTAssertTrue(ImageTools.isBlank(black))
        let gray = try XCTUnwrap(ImageTools.makeImage(rgba: solid(320, 200, 128, 128, 128), width: 320, height: 200))
        XCTAssertTrue(ImageTools.isBlank(gray))

        // A text-console-like frame: black with a white band of "text" in the upper part.
        var console = solid(320, 200, 0, 0, 0)
        for y in 20..<40 {
            for x in 10..<300 {
                let i = (y * 320 + x) * 4
                console[i] = 230; console[i + 1] = 230; console[i + 2] = 230
            }
        }
        let frame = try XCTUnwrap(ImageTools.makeImage(rgba: console, width: 320, height: 200))
        XCTAssertFalse(ImageTools.isBlank(frame))
    }

    func testResampleAndPNG() throws {
        var px = solid(64, 32, 255, 0, 0)
        for i in stride(from: 0, to: px.count / 2, by: 4) { px[i] = 0; px[i + 2] = 255 }
        let image = try XCTUnwrap(ImageTools.makeImage(rgba: px, width: 64, height: 32))
        let scaled = ImageTools.resample(image, width: 128, height: 64)
        XCTAssertEqual(scaled.width, 128)
        XCTAssertEqual(scaled.height, 64)
        XCTAssertTrue(ImageTools.resample(image, width: 64, height: 32) === image)

        let png = try ImageTools.pngData(scaled)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(ImageTools.pngSize(png), PixelSize(width: 128, height: 64))
        XCTAssertNil(ImageTools.pngSize(Data("not a png".utf8)))
    }
}
