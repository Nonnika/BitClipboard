import XCTest
@testable import BitClipboardCore

private actor EmbeddingFixture: TextEmbeddingProvider {
    var calls: [(texts: [String], isQuery: Bool)] = []
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        calls.append((texts, isQuery))
        return texts.map { _ in
            var vector = [Float](repeating: 0, count: SemanticSearchIndex.dimensions)
            vector[0] = invalid ? .nan : 2
            return vector
        }
    }
}

private actor SuspendedEmbeddingFixture: TextEmbeddingProvider {
    var continuation: CheckedContinuation<Void, Never>?
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        await withCheckedContinuation { continuation = $0 }
        return texts.map { _ in [Float](repeating: 1, count: SemanticSearchIndex.dimensions) }
    }
    func waitUntilStarted() async throws {
        while continuation == nil { try await Task.sleep(nanoseconds: 1_000_000) }
    }
    func complete() { continuation?.resume(); continuation = nil }
}

final class SemanticSearchTests: XCTestCase {
    private func item(_ text: String, source: String = "Notes", pinned: Bool = false, date: Double = 0) -> ClipboardItem {
        ClipboardItem(content: ClipboardContent(kind: .text, text: text), imageFilename: nil, source: source,
                      createdAt: Date(timeIntervalSince1970: date), isPinned: pinned)
    }

    func testHybridRankingRetainsExactMatchesAndPrioritizesRelevanceOverPins() {
        let exact = item("会议地址 https://example.com")
        let related = item("明天十点讨论项目进度", date: 1)
        let lessRelated = item("电话会议纪要", pinned: true, date: 2)
        let unrelated = item("今天晚饭吃面条", date: 3)
        XCTAssertEqual(SearchRanking.results(items: [unrelated, lessRelated, related, exact], query: "会议地址",
                                             semanticScores: [related.id: 0.8, lessRelated.id: 0.76, unrelated.id: 0.68]),
                       [exact, related, lessRelated])
        XCTAssertEqual(SearchRanking.results(items: [related, exact], query: "  EXAMPLE.COM  "), [exact])
        XCTAssertEqual(SearchRanking.results(items: [related, exact], query: "Notes"), [related, exact])
        XCTAssertEqual(SearchRanking.results(items: [exact, lessRelated, unrelated], query: " \n "), [lessRelated, unrelated, exact])
    }

    func testMultiwordKeywordFallbackAndInvalidScores() {
        let match = item("error happened while connecting to database")
        let other = item("lunch")
        XCTAssertEqual(SearchRanking.results(items: [other, match], query: "database error",
                                             semanticScores: [other.id: .nan]), [match])
        XCTAssertTrue(SearchRanking.results(items: [other], query: "query", semanticScores: [other.id: .infinity]).isEmpty)
    }

    func testContentTypeQueriesReturnOnlyMatchingRecordsWithoutEmbeddings() {
        let image = ClipboardItem(content: ClipboardContent(kind: .image, text: "100 × 100"), imageFilename: "image.png", source: "Preview")
        let link = ClipboardItem(content: ClipboardContent(kind: .link, text: "https://example.com"), imageFilename: nil, source: "Safari")
        let text = item("图片格式说明")
        let items = [text, link, image]
        for query in ["图片", "照片", "截图", " IMAGES "] {
            XCTAssertEqual(SearchRanking.results(items: items, query: query, semanticScores: [text.id: 0.99, link.id: 0.99]), [image])
        }
        XCTAssertEqual(SearchRanking.results(items: items, query: "网址"), [link])
        XCTAssertEqual(SearchRanking.results(items: items, query: "文字"), [text])
        XCTAssertTrue(SearchRanking.results(items: [text, link], query: "图片").isEmpty)
        XCTAssertNil(SearchRanking.requestedKind(for: "图片格式说明"))
    }

    func testWeakSemanticScoresAreExcludedAndExactMatchesAlwaysRemain() {
        let exact = item("想找的关键词")
        let color = item("#FFFFFF")
        let website = item("paperpass.com")
        let related = item("意思相近的文字")
        let distant = item("不相关的段落")
        let items = [exact, color, website, related, distant]
        XCTAssertTrue(SearchRanking.results(items: items, query: "没有匹配的描述", semanticScores: [color.id: 0.69, website.id: 0.71]).isEmpty)
        XCTAssertEqual(SearchRanking.results(items: items, query: "关键词", semanticScores: [exact.id: 0.3, related.id: 0.85, distant.id: 0.76, color.id: 0.7]), [exact, related])
    }

    func testCacheReuseSourceMetadataPruningAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("embeddings.json")
        let provider = EmbeddingFixture()
        let index = SemanticSearchIndex(provider: provider, cacheURL: url)
        var document = item("明天上午十点开会")
        let first = try await index.scores(query: "会议安排", items: [document])
        XCTAssertEqual(first[document.id], 1)
        _ = try await index.scores(query: "会议安排", items: [document])
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[0].isQuery)
        XCTAssertEqual(calls[0].texts, ["title: none | text: 明天上午十点开会"])
        XCTAssertTrue(calls[1].isQuery)
        document.source = "Safari"
        _ = try await index.scores(query: "会议安排", items: [document])
        let updatedCalls = await provider.calls
        XCTAssertEqual(updatedCalls.count, 2)
        let reloadedProvider = EmbeddingFixture()
        let reloaded = SemanticSearchIndex(provider: reloadedProvider, cacheURL: url)
        _ = try await reloaded.scores(query: "会议安排", items: [document])
        let reloadedCalls = await reloadedProvider.calls
        XCTAssertEqual(reloadedCalls.count, 1)
        XCTAssertTrue(reloadedCalls[0].isQuery)
        var oldCache = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        oldCache["version"] = "old-model"
        try JSONSerialization.data(withJSONObject: oldCache).write(to: url)
        let newProvider = EmbeddingFixture()
        let newIndex = SemanticSearchIndex(provider: newProvider, cacheURL: url)
        _ = try await newIndex.scores(query: "会议安排", items: [document])
        let newCalls = await newProvider.calls
        XCTAssertEqual(newCalls.count, 2)
        try await reloaded.prune(items: [])
        let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        // Dictionaries with UUID keys are encoded as alternating key/value arrays.
        XCTAssertEqual((cache["entries"] as? [Any])?.count, 0)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testCorruptCacheIsRebuiltAndInvalidEmbeddingsAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("embeddings.json")
        try Data("broken cache".utf8).write(to: url)
        let invalid = SemanticSearchIndex(provider: EmbeddingFixture(invalid: true), cacheURL: url)
        do {
            _ = try await invalid.scores(query: "q", items: [item("d")])
            XCTFail("Expected an invalid vector error")
        } catch { XCTAssertTrue(error is SemanticSearchError) }
        XCTAssertEqual(try String(contentsOf: url), "broken cache")
        let valid = SemanticSearchIndex(provider: EmbeddingFixture(), cacheURL: url)
        let scores = try await valid.scores(query: "q", items: [item("d")])
        XCTAssertEqual(scores.count, 1)
    }

    func testLongUnicodeContentHasOverlappingChunksAndImagesAreNotEmbedded() async throws {
        let text = String(repeating: "中", count: 1400) + "边界词" + String(repeating: "文", count: 500)
        let chunks = SemanticSearchIndex.documentChunks(item(text))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].contains("边界词"))
        XCTAssertTrue(chunks[1].contains("边界词"))
        XCTAssertEqual(SemanticSearchIndex.documentChunks(item(String(repeating: "a", count: 50000))).count, 18)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = EmbeddingFixture()
        let index = SemanticSearchIndex(provider: provider, cacheURL: directory.appendingPathComponent("cache.json"))
        let image = ClipboardItem(content: ClipboardContent(kind: .image, text: "100 × 100"), imageFilename: "x.png", source: "Preview")
        let scores = try await index.scores(query: "照片", items: [image])
        XCTAssertTrue(scores.isEmpty)
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].isQuery)
    }

    func testNewRecordsAreBatchedAndOnlyChangedRecordsAreReembedded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = EmbeddingFixture()
        let index = SemanticSearchIndex(provider: provider, cacheURL: directory.appendingPathComponent("cache.json"))
        var items = (0..<10).map { item("record \($0)") }
        _ = try await index.scores(query: "q", items: items)
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.texts.count }, [8, 2, 1])
        items[0].isPinned = true
        items[0].createdAt = Date()
        _ = try await index.scores(query: "q", items: items)
        let metadataCalls = await provider.calls
        XCTAssertEqual(metadataCalls.count, 3)
        items.append(item("new record"))
        _ = try await index.scores(query: "q", items: items)
        let updated = await provider.calls
        XCTAssertEqual(updated.count, 4)
        XCTAssertEqual(updated.last?.texts, ["title: none | text: new record"])
    }

    func testCancelledSearchDoesNotPersistResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let provider = SuspendedEmbeddingFixture()
        let index = SemanticSearchIndex(provider: provider, cacheURL: url)
        let task = Task { try await index.scores(query: "q", items: [item("d")]) }
        try await provider.waitUntilStarted()
        task.cancel()
        await provider.complete()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLocalWorkerProtocolReusesProcessAndRecoversAfterStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.py")
        try """
        import json, sys
        count = 0
        for line in sys.stdin:
            r = json.loads(line)
            assert r['texts'][0] == '中文\\nsecond line'
            count += 1
            print(json.dumps({'vectors': [[count, int(r['isQuery'])]]}), flush=True)
        """.write(to: worker, atomically: true, encoding: .utf8)
        let provider = LocalEmbeddingProvider(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker, runtimeURL: directory, timeout: 5)
        defer { provider.stop() }
        let first = try await provider.embed(["中文\nsecond line"], isQuery: false)
        let second = try await provider.embed(["中文\nsecond line"], isQuery: true)
        XCTAssertEqual(first, [[1, 0]])
        XCTAssertEqual(second, [[2, 1]])
        provider.stop()
        let restarted = try await provider.embed(["中文\nsecond line"], isQuery: true)
        XCTAssertEqual(restarted, [[1, 1]])
    }

    func testLocalWorkerFailureAndTimeoutDoNotHangSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.py")
        try "import sys; sys.exit(1)".write(to: worker, atomically: true, encoding: .utf8)
        let provider = LocalEmbeddingProvider(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker, runtimeURL: directory, timeout: 0.5)
        defer { provider.stop() }
        do { _ = try await provider.embed(["q"], isQuery: true); XCTFail("Expected worker failure") }
        catch { XCTAssertTrue(error is SemanticSearchError) }
        try "import time; time.sleep(30)".write(to: worker, atomically: true, encoding: .utf8)
        let start = Date()
        do { _ = try await provider.embed(["q"], isQuery: true); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error is SemanticSearchError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRealEmbeddingGemmaChineseAndCrossLanguageRetrieval() async throws {
        guard let path = ProcessInfo.processInfo.environment["BITCLIPBOARD_TEST_RUNTIME"] else {
            throw XCTSkip("Set BITCLIPBOARD_TEST_RUNTIME to run the downloaded model")
        }
        let runtime = URL(fileURLWithPath: path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provider = LocalEmbeddingProvider(pythonURL: runtime.appendingPathComponent("venv/bin/python3"),
                                              workerURL: root.appendingPathComponent("Sources/BitClipboard/SemanticRuntime/embedding_worker.py"), runtimeURL: runtime)
        defer { provider.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = SemanticSearchIndex(provider: provider, cacheURL: directory.appendingPathComponent("cache.json"))
        let meeting = item("明天上午十点在办公室讨论项目进度")
        let database = item("PostgreSQL: connection refused. Check hostname and port 5432.")
        let dinner = item("今晚下厨，做番茄炒蛋和米饭")
        let color = item("#FFFFFF")
        let website = item("paperpass.com")
        let items = [meeting, database, dinner, color, website]
        for (query, expected) in [("开会安排", meeting), ("怎么解决数据库连不上", database), ("晚上吃什么", dinner)] {
            let scores = try await index.scores(query: query, items: items)
            XCTAssertEqual(SearchRanking.results(items: items, query: query, semanticScores: scores), [expected],
                           "Unexpected ranking for \(query): \(scores)")
        }
        let noMatchQuery = "完全没有的东西 xyz987"
        let scores = try await index.scores(query: noMatchQuery, items: [color, website])
        XCTAssertTrue(SearchRanking.results(items: [color, website], query: noMatchQuery, semanticScores: scores).isEmpty)
    }
}
