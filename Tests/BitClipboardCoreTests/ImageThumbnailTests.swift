import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BitClipboardCore

final class ImageThumbnailTests: XCTestCase {
    func testLargeImageIsDownsampledWithoutChangingOriginal() throws {
        let url = try image(width: 3200, height: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let thumbnail = try XCTUnwrap(ImageThumbnail.load(from: url))
        XCTAssertEqual(thumbnail.originalSize, CGSize(width: 3200, height: 1600))
        XCTAssertEqual(thumbnail.image.width, 800)
        XCTAssertEqual(thumbnail.image.height, 400)
        XCTAssertLessThanOrEqual(thumbnail.image.bytesPerRow * thumbnail.image.height, 2 * 1024 * 1024)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSmallImagesRetainTheirSize() throws {
        let url = try image(width: 2, height: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnail = try XCTUnwrap(ImageThumbnail.load(from: url))
        XCTAssertEqual(thumbnail.originalSize, CGSize(width: 2, height: 3))
        XCTAssertEqual(thumbnail.image.width, 2)
        XCTAssertEqual(thumbnail.image.height, 3)
    }

    func testUnreadableImagesAndInvalidLimitsReturnNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("invalid image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ImageThumbnail.load(from: url))
        XCTAssertNil(ImageThumbnail.load(from: url, maximumPixelSize: 0))
        XCTAssertNil(ImageThumbnail.load(from: url.appendingPathExtension("missing")))
    }

    private func image(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
