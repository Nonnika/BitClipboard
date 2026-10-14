import Foundation

/// A serial background queue keeps a single model process warm, without blocking the UI or Swift's cooperative executor.
public final class LocalEmbeddingProvider: TextEmbeddingProvider, @unchecked Sendable {
    private struct Request: Encodable { let texts: [String]; let isQuery: Bool }
    private struct Reply: Decodable { let vectors: [[Float]]?; let error: String? }
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }
    private let pythonURL: URL
    private let workerURL: URL
    private let runtimeURL: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "BitClipboard.embeddings", qos: .utility)
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    public init(pythonURL: URL, workerURL: URL, runtimeURL: URL, timeout: TimeInterval = 180) {
        self.pythonURL = pythonURL
        self.workerURL = workerURL
        self.runtimeURL = runtimeURL
        self.timeout = timeout
    }

    public func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        try Task.checkCancellation()
        let current = currentGeneration()
        let state = CancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try state.check()
                        let vectors = try self.request(texts, isQuery: isQuery, generation: current)
                        try state.check()
                        continuation.resume(returning: vectors)
                    }
                    catch is CancellationError { continuation.resume(throwing: CancellationError()) }
                    catch { self.stop(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.cancel() }
    }

    /// Safe to call from the main thread, including on application termination.
    public func stop() {
        lock.lock()
        let current = process
        process = nil
        generation += 1
        lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }

    deinit { stop() }

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    private func start(generation expected: Int) throws -> Process {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { throw CancellationError() }
        if let current = process, current.isRunning { return current }
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.fileExists(atPath: workerURL.path) else { throw SemanticSearchError.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = pythonURL
        child.arguments = ["-u", workerURL.path, "--runtime", runtimeURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        // Runtime errors never log private clipboard content.
        child.standardError = FileHandle.nullDevice
        try child.run()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer.removeAll()
        process = child
        return child
    }

    private func request(_ texts: [String], isQuery: Bool, generation: Int) throws -> [[Float]] {
        let child = try start(generation: generation)
        let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        var data = try JSONEncoder().encode(Request(texts: texts, isQuery: isQuery))
        data.append(0x0A)
        try input?.write(contentsOf: data)
        while !buffer.contains(0x0A) {
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                throw SemanticSearchError.workerFailed
            }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw SemanticSearchError.invalidVectors }
        }
        let end = buffer.firstIndex(of: 0x0A)!
        let line = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        let reply = try JSONDecoder().decode(Reply.self, from: line)
        guard reply.error == nil, let vectors = reply.vectors else { throw SemanticSearchError.workerFailed }
        return vectors
    }
}
