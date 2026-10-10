import Foundation
import CryptoKit

public enum ClipboardKind: String, Codable, CaseIterable {
    // `files` remains decodable only for migrating older histories.
    case text, image, link, files
    public var title: String {
        switch self {
        case .text: return "文字"
        case .image: return "图片"
        case .link: return "链接"
        case .files: return "文件"
        }
    }
    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .link: return "link"
        case .files: return "folder"
        }
    }
}

public struct ClipboardContent {
    public let kind: ClipboardKind
    public let text: String
    public let imageData: Data?
    public let fileURLs: [URL]

    public init(kind: ClipboardKind, text: String = "", imageData: Data? = nil, fileURLs: [URL] = []) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.fileURLs = fileURLs
    }

    public var fingerprint: String {
        var data = Data(kind.rawValue.utf8)
        data.append(imageData ?? Data(text.utf8))
        for url in fileURLs { data.append(Data(url.absoluteString.utf8)); data.append(0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClipboardItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public let kind: ClipboardKind
    public let text: String
    public let imageFilename: String?
    public let fileURLs: [URL]
    public let fingerprint: String
    public var createdAt: Date
    public var source: String
    public var isPinned: Bool

    public init(content: ClipboardContent, imageFilename: String?, source: String,
                id: UUID = UUID(), createdAt: Date = Date(), isPinned: Bool = false) {
        self.id = id
        kind = content.kind
        text = content.text
        self.imageFilename = imageFilename
        fileURLs = content.fileURLs
        fingerprint = content.fingerprint
        self.createdAt = createdAt
        self.source = source
        self.isPinned = isPinned
    }
}
