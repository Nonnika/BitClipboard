import Foundation

/// Disk writes are atomic. Images are stored separately so the index stays small.
public final class HistoryRepository {
    public let directory: URL
    public private(set) var items: [ClipboardItem] = []
    private let manager = FileManager.default
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private var imageDirectory: URL { directory.appendingPathComponent("Images", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        try manager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        // This is private clipboard data; restrict access to the current user.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectory.path)
        if manager.fileExists(atPath: indexURL.path) {
            items = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: indexURL))
            try migrateFileRecords()
        }
    }

    public func imageURL(for item: ClipboardItem) -> URL? {
        guard let filename = item.imageFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        return imageDirectory.appendingPathComponent(filename)
    }

    public func add(_ content: ClipboardContent, source: String, limit: Int) throws {
        guard content.kind != .files else { return }
        let previous = items
        var newImage: URL?
        if let existing = items.firstIndex(where: { $0.fingerprint == content.fingerprint }) {
            var item = items.remove(at: existing)
            item.createdAt = Date()
            item.source = source
            items.insert(item, at: 0)
        } else {
            var filename: String?
            if let data = content.imageData {
                filename = UUID().uuidString + ".png"
                let url = imageDirectory.appendingPathComponent(filename!)
                try data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                newImage = url
            }
            items.insert(ClipboardItem(content: content, imageFilename: filename, source: source), at: 0)
        }
        let removed = trim(limit: limit)
        do { try save() }
        catch {
            items = previous
            if let newImage { try? manager.removeItem(at: newImage) }
            throw error
        }
        removeImages(for: removed)
    }

    public func togglePin(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items
        items[index].isPinned.toggle()
        do { try save() } catch { items = previous; throw error }
    }

    public func delete(_ id: UUID) throws {
        try remove(where: { $0.id == id })
    }

    public func clearUnpinned() throws {
        try remove(where: { !$0.isPinned })
    }

    public func enforceLimit(_ limit: Int) throws {
        let previous = items
        let removed = trim(limit: limit)
        do { try save() } catch { items = previous; throw error }
        removeImages(for: removed)
    }

    private func migrateFileRecords() throws {
        guard items.contains(where: { $0.kind == .files }) else { return }
        let previous = items
        var migrated: [ClipboardItem] = []
        var createdImages: [URL] = []
        do {
            for item in previous {
                guard item.kind == .files else { migrated.append(item); continue }
                guard item.fileURLs.count == 1, let url = item.fileURLs.first,
                      let content = PasteboardReader.imageFileContent(at: url),
                      let data = content.imageData else { continue }
                let filename = UUID().uuidString + ".png"
                let imageURL = imageDirectory.appendingPathComponent(filename)
                createdImages.append(imageURL)
                try data.write(to: imageURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
                migrated.append(ClipboardItem(content: content, imageFilename: filename, source: item.source,
                                              id: item.id, createdAt: item.createdAt, isPinned: item.isPinned))
            }
            items = migrated
            try save()
        } catch {
            items = previous
            for url in createdImages { try? manager.removeItem(at: url) }
            throw error
        }
    }

    private func trim(limit: Int) -> [ClipboardItem] {
        var count = 0
        let removed = items.filter { item in
            if item.isPinned { return false }
            count += 1
            return count > max(1, limit)
        }
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        return removed
    }

    private func remove(where predicate: (ClipboardItem) -> Bool) throws {
        let previous = items
        let removed = items.filter(predicate)
        items.removeAll(where: predicate)
        do { try save() } catch { items = previous; throw error }
        removeImages(for: removed)
    }

    private func save() throws {
        try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func removeImages(for items: [ClipboardItem]) {
        for item in items {
            if let url = imageURL(for: item) { try? manager.removeItem(at: url) }
        }
    }
}
