import Foundation
import CryptoKit

public enum SearchRanking {
    // Cosine similarity is not a relevance probability. This model's unrelated short texts
    // often score 0.6–0.7, so keep only strong matches close to the best candidate.
    public static let minimumSemanticScore: Float = 0.72
    public static let semanticScoreWindow: Float = 0.06

    public static func requestedKind(for query: String) -> ClipboardKind? {
        switch query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "图片", "图像", "照片", "截图", "image", "images", "photo", "photos", "screenshot", "screenshots": return .image
        case "文字", "文本", "text": return .text
        case "链接", "网址", "link", "links", "url", "urls": return .link
        default: return nil
        }
    }

    public static func results(items: [ClipboardItem], query: String, semanticScores: [UUID: Float] = [:]) -> [ClipboardItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items.sorted(by: historyOrder) }
        if let kind = requestedKind(for: query) {
            return items.filter { $0.kind == kind }.sorted(by: historyOrder)
        }
        let best = items.compactMap { semanticScores[$0.id] }.filter { $0.isFinite }.max() ?? 0
        let threshold = max(minimumSemanticScore, best - semanticScoreWindow)
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func lexical(_ item: ClipboardItem) -> Int {
            let text = item.text + " " + item.source
            if text.localizedCaseInsensitiveContains(query) { return 2 }
            return terms.count > 1 && terms.allSatisfy { text.localizedCaseInsensitiveContains($0) } ? 1 : 0
        }
        return items.filter {
            lexical($0) > 0 || semanticScores[$0.id].map { $0.isFinite && $0 >= threshold } == true
        }.sorted {
            let lhs = lexical($0), rhs = lexical($1)
            if lhs != rhs { return lhs > rhs }
            let left = semanticScores[$0.id].flatMap { $0.isFinite ? $0 : nil } ?? -1
            let right = semanticScores[$1.id].flatMap { $0.isFinite ? $0 : nil } ?? -1
            if left != right { return left > right }
            return historyOrder($0, $1)
        }
    }

    private static func historyOrder(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public protocol TextEmbeddingProvider: Sendable {
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]]
}

public enum SemanticSearchError: LocalizedError {
    case unavailable, invalidVectors, workerFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "请先安装本地语义搜索模型。"
        case .invalidVectors: return "模型返回了无效的向量，请重新安装模型。"
        case .workerFailed: return "本地模型启动失败，请检查安装或重新安装模型。"
        }
    }
}

/// Stores derived vectors separately from history. A model/prompt change invalidates the entire cache.
public actor SemanticSearchIndex {
    public static let dimensions = 256
    public static let cacheVersion = "embeddinggemma-2/914f7f89142e33e77833254d9c9b90c3cef7303b/search-v2-no-title/256"
    private struct Entry: Codable {
        let signature: String
        let vectors: [[Float]]
    }
    private struct Cache: Codable {
        let version: String
        var entries: [UUID: Entry]
    }
    private let provider: any TextEmbeddingProvider
    private let cacheURL: URL
    private var entries: [UUID: Entry] = [:]
    private var loadedCache = false
    private var queryVectors: [String: [Float]] = [:]

    public init(provider: any TextEmbeddingProvider, cacheURL: URL) {
        self.provider = provider
        self.cacheURL = cacheURL
    }

    private func loadCache() {
        guard !loadedCache else { return }
        loadedCache = true
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == Self.cacheVersion {
            entries = cache.entries.filter { !$0.value.vectors.isEmpty && $0.value.vectors.allSatisfy(Self.isValid) }
        } else { entries = [:] }
    }

    public func prune(items: [ClipboardItem]) throws {
        try Task.checkCancellation()
        loadCache()
        let ids = Set(items.filter { $0.kind == .text || $0.kind == .link }.map(\.id))
        let count = entries.count
        entries = entries.filter { ids.contains($0.key) }
        if count != entries.count { try save() }
    }

    public func scores(query: String, items: [ClipboardItem]) async throws -> [UUID: Float] {
        try prune(items: items)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [:] }
        var work: [(id: UUID, text: String)] = []
        var signatures: [UUID: String] = [:]
        var chunkCounts: [UUID: Int] = [:]
        var collected: [UUID: [[Float]]] = [:]
        for item in items where item.kind == .text || item.kind == .link {
            try Task.checkCancellation()
            let chunks = Self.documentChunks(item)
            let signature = SHA256.hash(data: Data(chunks.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
            guard entries[item.id]?.signature != signature else { continue }
            signatures[item.id] = signature
            chunkCounts[item.id] = chunks.count
            work += chunks.map { (item.id, $0) }
        }
        // Batch across records as well as chunks; most clipboard records contain only a few words.
        for start in stride(from: 0, to: work.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(work[start..<min(start + 8, work.count)])
            let output = try await provider.embed(batch.map(\.text), isQuery: false)
            try Task.checkCancellation()
            guard output.count == batch.count else { throw SemanticSearchError.invalidVectors }
            let normalized = try output.map(Self.normalized)
            for (job, vector) in zip(batch, normalized) {
                collected[job.id, default: []].append(vector)
                if collected[job.id]?.count == chunkCounts[job.id], let signature = signatures[job.id], let vectors = collected[job.id] {
                    entries[job.id] = Entry(signature: signature, vectors: vectors)
                }
            }
            try save()
        }
        try Task.checkCancellation()
        let queryKey = String(query.prefix(2000))
        let vector: [Float]
        if let cached = queryVectors[queryKey] { vector = cached }
        else {
            let output = try await provider.embed([queryKey], isQuery: true)
            try Task.checkCancellation()
            guard output.count == 1, let first = output.first else { throw SemanticSearchError.invalidVectors }
            vector = try Self.normalized(first)
            if queryVectors.count >= 16 { queryVectors.removeAll() }
            queryVectors[queryKey] = vector
        }
        var scores: [UUID: Float] = [:]
        for item in items {
            guard let entry = entries[item.id] else { continue }
            scores[item.id] = entry.vectors.map { zip(vector, $0).reduce(Float(0)) { $0 + $1.0 * $1.1 } }.max()
        }
        return scores
    }

    /// Overlap preserves phrases at boundaries; cap work for very large clipboard records.
    public static func documentChunks(_ item: ClipboardItem) -> [String] {
        // Clipboard content has no document title. Source apps are matched lexically,
        // rather than allowing an unrelated application name to skew the embedding.
        let title = "none"
        let characters = Array(item.text.prefix(24000))
        guard !characters.isEmpty else { return ["title: \(title) | text: "] }
        return stride(from: 0, to: characters.count, by: 1400).map {
            "title: \(title) | text: " + String(characters[$0..<min($0 + 1600, characters.count)])
        }
    }

    private static func isValid(_ vector: [Float]) -> Bool {
        vector.count == dimensions && vector.allSatisfy(\.isFinite) && vector.contains { $0 != 0 }
    }

    private static func normalized(_ vector: [Float]) throws -> [Float] {
        guard isValid(vector) else { throw SemanticSearchError.invalidVectors }
        let length = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        return vector.map { Float(Double($0) / length) }
    }

    private func save() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Cache(version: Self.cacheVersion, entries: entries)).write(to: cacheURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
