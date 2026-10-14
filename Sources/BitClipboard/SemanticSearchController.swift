import AppKit
import Combine
import BitClipboardCore

@MainActor
final class SemanticSearchController: ObservableObject {
    @Published var query = "" { didSet { refresh() } }
    @Published var enabled = UserDefaults.standard.object(forKey: "semanticSearchEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "semanticSearchEnabled")
            if !enabled { provider?.stop() }
            refresh()
        }
    }
    @Published private(set) var scores: [UUID: Float] = [:]
    @Published private(set) var status = ""
    @Published private(set) var isSearching = false
    @Published private(set) var isInstalling = false
    @Published private(set) var ready = false
    @Published private(set) var installationProgress: ModelInstallationProgress?
    @Published private(set) var installationError: String?
    private var items: [ClipboardItem] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var provider: LocalEmbeddingProvider?
    private var index: SemanticSearchIndex?
    private let directory: URL
    private var runtime: URL {
        if let path = ProcessInfo.processInfo.environment["BITCLIPBOARD_SEMANTIC_RUNTIME"] { return URL(fileURLWithPath: path) }
        return directory.appendingPathComponent("SemanticSearch", isDirectory: true)
    }
    private var resources: URL { Bundle.module.url(forResource: "SemanticRuntime", withExtension: nil)! }

    init(directory: URL) {
        self.directory = directory
        ready = FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ready").path)
        status = ready ? "语义搜索已就绪" : "请在设置中安装语义搜索模型"
    }

    func update(items: [ClipboardItem]) {
        guard self.items != items else { return }
        self.items = items
        refresh()
    }

    func shutdown() {
        task?.cancel()
        provider?.stop()
    }

    private func refresh() {
        task?.cancel()
        generation += 1
        let current = generation, snapshot = items, searchQuery = query
        scores = [:]
        isSearching = false
        guard !isInstalling else { return }
        ready = FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ready").path)
        if index == nil {
            let provider = LocalEmbeddingProvider(pythonURL: runtime.appendingPathComponent("venv/bin/python3"),
                                                  workerURL: resources.appendingPathComponent("embedding_worker.py"), runtimeURL: runtime)
            self.provider = provider
            index = SemanticSearchIndex(provider: provider, cacheURL: directory.appendingPathComponent("embeddings.json"))
        }
        guard let index else { return }
        let kind = SearchRanking.requestedKind(for: searchQuery)
        let shouldSearch = enabled && ready && kind == nil && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        status = !enabled ? "关键词搜索" : !ready ? "请在设置中安装语义搜索模型" : "语义搜索已就绪"
        isSearching = shouldSearch
        if shouldSearch { status = "正在查找语义相关内容…" }
        if let kind { status = "按内容类型筛选：\(kind.title)" }
        task = Task {
            do {
                try Task.checkCancellation()
                // Prune even when semantic search is disabled or the query is empty.
                try await index.prune(items: snapshot)
                guard shouldSearch else { return }
                try await Task.sleep(nanoseconds: 300_000_000)
                let result = try await index.scores(query: searchQuery, items: snapshot)
                guard !Task.isCancelled, generation == current else { return }
                scores = result
                isSearching = false
                status = "按关键词与语义相关度排序"
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                isSearching = false
                status = "语义搜索不可用，已使用关键词搜索"
            }
        }
    }

    func install() {
        guard !isInstalling else { return }
        shutdown()
        isInstalling = true
        isSearching = false
        scores = [:]
        installationError = nil
        installationProgress = nil
        status = "正在安装模型，可继续使用关键词搜索"
        let runtime = runtime, script = resources.appendingPathComponent("setup.sh")
        let logURL = directory.appendingPathComponent("semantic-setup.log")
        Task {
            do {
                for try await progress in ModelInstallation.events(script: script, runtime: runtime, logURL: logURL) {
                    installationProgress = progress
                }
                guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ready").path) else {
                    throw ModelInstallationError.failed
                }
                isInstalling = false
                ready = true
                index = nil
                provider = nil
                refresh()
            } catch {
                isInstalling = false
                ready = FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ready").path)
                installationError = error.localizedDescription
                status = "模型安装失败，可在设置中重试"
            }
        }
    }

    func openInstallLog() { NSWorkspace.shared.open(directory.appendingPathComponent("semantic-setup.log")) }

}
