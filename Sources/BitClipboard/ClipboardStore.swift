import AppKit
import Combine
import BitClipboardCore

@MainActor
final class ClipboardStore: ObservableObject {
    let semanticSearch: SemanticSearchController
    @Published private(set) var items: [ClipboardItem] = []
    @Published var error: String?
    @Published var copiedID: UUID?
    @Published var copiedTokenID: String?
    @Published var isPaused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "paused")
            lastChange = NSPasteboard.general.changeCount
        }
    }
    @Published var historyLimit: Int = UserDefaults.standard.integer(forKey: "historyLimit") == 0 ? 200 : UserDefaults.standard.integer(forKey: "historyLimit") {
        didSet {
            UserDefaults.standard.set(historyLimit, forKey: "historyLimit")
            perform { try repository?.enforceLimit(historyLimit) }
        }
    }
    private var repository: HistoryRepository?
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var feedbackReset: DispatchWorkItem?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitClipboard", isDirectory: true)
        semanticSearch = SemanticSearchController(directory: directory)
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            repository = try HistoryRepository(directory: support.appendingPathComponent("BitClipboard", isDirectory: true))
            items = repository?.items ?? []
            semanticSearch.update(items: items)
        } catch {
            self.error = "无法读取本地历史：\(error.localizedDescription)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard !isPaused, repository != nil, let content = PasteboardReader.read(pasteboard) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用"
        perform { try repository?.add(content, source: source, limit: historyLimit) }
    }

    func copy(_ item: ClipboardItem) {
        guard item.kind != .files else { return }
        let pasteboard = NSPasteboard.general
        // Read the data before clearing the user's clipboard.
        var image: NSImage?
        if item.kind == .image {
            guard let url = imageURL(for: item), let loaded = NSImage(contentsOf: url) else {
                error = "图片文件不可用，无法复制。"
                return
            }
            image = loaded
        }
        pasteboard.clearContents()
        let success: Bool
        if let image { success = pasteboard.writeObjects([image]) }
        else { success = pasteboard.setString(item.text, forType: .string) }
        lastChange = pasteboard.changeCount
        guard success else { error = "复制失败，请重试。"; return }
        showCopyFeedback(itemID: item.id)
    }

    func copy(_ token: ExtractedToken, from item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(token.value, forType: .string)
        lastChange = pasteboard.changeCount
        guard success else { error = "复制失败，请重试。"; return }
        showCopyFeedback(tokenID: item.id.uuidString + ":" + token.id)
    }

    private func showCopyFeedback(itemID: UUID? = nil, tokenID: String? = nil) {
        feedbackReset?.cancel()
        copiedID = itemID
        copiedTokenID = tokenID
        let reset = DispatchWorkItem { [weak self] in
            self?.copiedID = nil
            self?.copiedTokenID = nil
        }
        feedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }

    func pin(_ item: ClipboardItem) { perform { try repository?.togglePin(item.id) } }
    func delete(_ item: ClipboardItem) { perform { try repository?.delete(item.id) } }
    func clear() { perform { try repository?.clearUnpinned() } }
    func imageURL(for item: ClipboardItem) -> URL? { repository?.imageURL(for: item) }

    func previewImageURL(for item: ClipboardItem) -> URL? {
        if item.kind == .image { return imageURL(for: item) }
        return nil
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            items = repository?.items ?? []
            semanticSearch.update(items: items)
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}
