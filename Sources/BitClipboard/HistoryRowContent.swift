import AppKit
import Combine
import BitClipboardCore

/// Shared, bounded cache. Only visible cards request work; decoding and regex run off the UI thread.
private final class HistoryContentCache {
    static let shared = HistoryContentCache()
    private let images = NSCache<NSURL, NSImage>()
    private let texts = NSCache<NSUUID, TextContent>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "BitClipboard.card-content"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var imageRequests: [URL: [(NSImage?) -> Void]] = [:]
    private var textRequests: [UUID: [(TextContent) -> Void]] = [:]

    final class TextContent: NSObject {
        let tokens: [ExtractedToken]
        init(_ text: String) { tokens = TextExtraction.extract(from: text) }
    }

    private init() {
        images.totalCostLimit = 32 * 1024 * 1024
        texts.totalCostLimit = 8 * 1024 * 1024
        texts.countLimit = 200
    }

    func image(at url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = images.object(forKey: url as NSURL) { completion(image); return }
        if imageRequests[url] != nil { imageRequests[url]?.append(completion); return }
        imageRequests[url] = [completion]
        queue.addOperation {
            let thumbnail = ImageThumbnail.load(from: url)
            DispatchQueue.main.async {
                let image = thumbnail.map { NSImage(cgImage: $0.image, size: $0.originalSize) }
                if let image, let thumbnail {
                    self.images.setObject(image, forKey: url as NSURL,
                                          cost: thumbnail.image.bytesPerRow * thumbnail.image.height)
                }
                let callbacks = self.imageRequests.removeValue(forKey: url) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    func text(for item: ClipboardItem, completion: @escaping (TextContent) -> Void) {
        if let text = texts.object(forKey: item.id as NSUUID) { completion(text); return }
        if textRequests[item.id] != nil { textRequests[item.id]?.append(completion); return }
        textRequests[item.id] = [completion]
        queue.addOperation {
            let text = TextContent(item.text)
            let cost = text.tokens.reduce(0) { $0 + $1.value.utf8.count }
            DispatchQueue.main.async {
                self.texts.setObject(text, forKey: item.id as NSUUID, cost: cost)
                let callbacks = self.textRequests.removeValue(forKey: item.id) ?? []
                callbacks.forEach { $0(text) }
            }
        }
    }
}

final class HistoryRowContent: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var tokens: [ExtractedToken] = []
    @Published private(set) var imageLoading = true
    let summary: String
    let imageSize: CGSize
    private var requested = false
    private var textLoaded = false

    init(item: ClipboardItem) {
        // Limit shaping work in the card. Copy and full preview still use the complete text.
        summary = String(item.text.prefix(600))
        let dimensions = item.kind == .image ? item.text.components(separatedBy: " × ") : []
        if item.kind == .image, dimensions.count == 2,
           let width = Double(dimensions[0]), let height = Double(dimensions[1]), width > 0, height > 0 {
            imageSize = CGSize(width: width, height: height)
        } else { imageSize = CGSize(width: 320, height: 160) }
    }

    func load(item: ClipboardItem, imageURL: URL?) {
        guard !requested else { return }
        requested = true
        if item.kind == .image {
            guard let imageURL else { imageLoading = false; return }
            HistoryContentCache.shared.image(at: imageURL) { [weak self] image in
                guard let self, self.requested else { return }
                self.image = image
                self.imageLoading = false
            }
        } else if item.kind == .text || item.kind == .link {
            guard !textLoaded else { return }
            HistoryContentCache.shared.text(for: item) { [weak self] text in
                self?.tokens = text.tokens
                self?.textLoaded = true
            }
        }
    }

    func unloadImage() {
        requested = false
        // Preserve the card's measured size while releasing its offscreen bitmap.
        image = nil
        imageLoading = true
    }
}

/// Updating hover should invalidate the keyboard handler, not the entire history list.
final class HoveredHistoryItem: ObservableObject {
    @Published var id: UUID?
}
