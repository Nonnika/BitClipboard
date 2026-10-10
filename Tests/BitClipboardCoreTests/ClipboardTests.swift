import XCTest
import AppKit
@testable import BitClipboardCore

final class ClipboardTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testDuplicateRetainsIdentityAndPinAfterReload() throws {
        let repository = try HistoryRepository(directory: directory)
        let content = ClipboardContent(kind: .text, text: "一段文字\n第二行")
        try repository.add(content, source: "Safari", limit: 200)
        let id = try XCTUnwrap(repository.items.first?.id)
        try repository.togglePin(id)
        try repository.add(content, source: "备忘录", limit: 200)
        let loaded = try HistoryRepository(directory: directory)
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items.first?.id, id)
        XCTAssertEqual(loaded.items.first?.source, "备忘录")
        XCTAssertEqual(loaded.items.first?.isPinned, true)
        XCTAssertEqual(loaded.items.first?.text, content.text)
    }

    func testLimitAndClearPreservePinnedImagesAndCleanDeletedFiles() throws {
        let repository = try HistoryRepository(directory: directory)
        try repository.add(ClipboardContent(kind: .image, text: "10 × 10", imageData: Data([1, 2, 3])), source: "Preview", limit: 2)
        let image = try XCTUnwrap(repository.items.first)
        let imageURL = try XCTUnwrap(repository.imageURL(for: image))
        try repository.togglePin(image.id)
        for value in ["one", "two", "three"] {
            try repository.add(ClipboardContent(kind: .text, text: value), source: "Test", limit: 2)
        }
        XCTAssertEqual(repository.items.count, 3)
        XCTAssertFalse(repository.items.contains { $0.text == "one" })
        try repository.clearUnpinned()
        XCTAssertEqual(repository.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        try repository.delete(image.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(try HistoryRepository(directory: directory).items.isEmpty)
    }

    func testPasteboardTextLinksSensitiveMarkersAndImageRoundTrip() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://example.com/path", forType: .string)
        XCTAssertEqual(PasteboardReader.read(pasteboard)?.kind, .link)
        pasteboard.clearContents()
        pasteboard.setString("https://blog.alphazero.top测试", forType: .string)
        let mixedText = try XCTUnwrap(PasteboardReader.read(pasteboard))
        XCTAssertEqual(mixedText.kind, .text)
        XCTAssertEqual(mixedText.text, "https://blog.alphazero.top测试")
        pasteboard.clearContents()
        pasteboard.setString("www.apple.com", forType: .string)
        XCTAssertEqual(PasteboardReader.read(pasteboard)?.kind, .link)
        pasteboard.clearContents()
        pasteboard.setString("保留换行\n和空格  ", forType: .string)
        XCTAssertEqual(PasteboardReader.read(pasteboard)?.text, "保留换行\n和空格  ")
        pasteboard.setData(Data(), forType: PasteboardReader.ignoredTypes[0])
        XCTAssertNil(PasteboardReader.read(pasteboard))
        pasteboard.clearContents()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(png, forType: .png)
        let content = try XCTUnwrap(PasteboardReader.read(pasteboard))
        XCTAssertEqual(content.kind, .image)
        let repository = try HistoryRepository(directory: directory)
        try repository.add(content, source: "Test", limit: 2)
        let loaded = try HistoryRepository(directory: directory)
        let imageURL = try XCTUnwrap(loaded.imageURL(for: loaded.items[0]))
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: imageURL))?.pixelsWide, 2)
    }

    func testNonImageFilesAndFoldersAreIgnoredEvenWithFallbackRepresentations() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try makeImageFixture()
        let imageData = try Data(contentsOf: image)
        let files = ["中文文件.txt", "document.pdf", "archive.zip", "fake.png"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("not an image".utf8).write(to: file) }
        for url in files + [folder] {
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setString(url.lastPathComponent, forType: .string)
            pasteboard.setData(imageData, forType: .png)
            XCTAssertNil(PasteboardReader.read(pasteboard), url.lastPathComponent)
        }
    }

    func testCopiedImageFileIsSavedAsPasteableImageIndependentOfOriginal() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let url = try makeImageFixture()
        pasteboard.writeObjects([url as NSURL])
        let content = try XCTUnwrap(PasteboardReader.read(pasteboard))
        XCTAssertEqual(content.kind, .image)
        XCTAssertTrue(content.fileURLs.isEmpty)
        let repository = try HistoryRepository(directory: directory.appendingPathComponent("History"))
        try repository.add(content, source: "Finder", limit: 200)
        try FileManager.default.removeItem(at: url)
        let loaded = try HistoryRepository(directory: repository.directory)
        let stored = try XCTUnwrap(loaded.items.first)
        let storedURL = try XCTUnwrap(loaded.imageURL(for: stored))
        XCTAssertEqual(try Data(contentsOf: storedURL), content.imageData)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: storedURL)))
        XCTAssertEqual(bitmap.pixelsWide, 2)
        XCTAssertEqual(bitmap.pixelsHigh, 3)
        let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        let image = try XCTUnwrap(NSImage(contentsOf: storedURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))
        XCTAssertEqual(PasteboardReader.read(pasteboard)?.kind, .image)
    }

    func testMultipleFileSelectionIsIgnored() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let first = try makeImageFixture()
        let second = directory.appendingPathComponent("second.png")
        try Data(contentsOf: first).write(to: second)
        pasteboard.writeObjects([first as NSURL, second as NSURL])
        XCTAssertNil(PasteboardReader.read(pasteboard))
    }

    func testLegacyFilesMigrateImagesAndRemoveOtherReferences() throws {
        let imageURL = try makeImageFixture()
        let documentURL = directory.appendingPathComponent("document.txt")
        try Data("original document".utf8).write(to: documentURL)
        let legacyImage = ClipboardItem(content: ClipboardContent(kind: .files, fileURLs: [imageURL]),
                                       imageFilename: nil, source: "Finder", createdAt: Date(timeIntervalSince1970: 100), isPinned: true)
        let legacyDocument = ClipboardItem(content: ClipboardContent(kind: .files, fileURLs: [documentURL]), imageFilename: nil, source: "Finder")
        let text = ClipboardItem(content: ClipboardContent(kind: .text, text: "保留文字"), imageFilename: nil, source: "Notes")
        let historyDirectory = directory.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyImage, legacyDocument, text]).write(to: historyDirectory.appendingPathComponent("history.json"))
        let migrated = try HistoryRepository(directory: historyDirectory)
        XCTAssertEqual(migrated.items.count, 2)
        let image = try XCTUnwrap(migrated.items.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.id, legacyImage.id)
        XCTAssertEqual(image.createdAt, legacyImage.createdAt)
        XCTAssertTrue(image.isPinned)
        XCTAssertTrue(image.fileURLs.isEmpty)
        XCTAssertEqual(migrated.items.last, text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        try FileManager.default.removeItem(at: imageURL)
        let reloaded = try HistoryRepository(directory: historyDirectory)
        XCTAssertEqual(reloaded.items, migrated.items)
        XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(reloaded.imageURL(for: image))))
    }

    func testRepositoryDoesNotAcceptNewFileReferences() throws {
        let repository = try HistoryRepository(directory: directory)
        try repository.add(ClipboardContent(kind: .files, fileURLs: [directory.appendingPathComponent("document.txt")]), source: "Finder", limit: 200)
        XCTAssertTrue(repository.items.isEmpty)
        XCTAssertTrue(try HistoryRepository(directory: directory).items.isEmpty)
    }

    private func makeImageFixture() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let color = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for x in 0..<2 { for y in 0..<3 { bitmap.setColor(color, atX: x, y: y) } }
        let url = directory.appendingPathComponent("image.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testCorruptedHistoryIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        let data = Data("broken history".utf8)
        try data.write(to: file)
        XCTAssertThrowsError(try HistoryRepository(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
