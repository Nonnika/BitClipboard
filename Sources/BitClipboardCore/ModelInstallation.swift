import Foundation

public struct ModelInstallationProgress: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case preparing, dependencies, download, verifying, complete }
    public let stage: Stage
    public let completed: Int64?
    public let total: Int64?
    public let filename: String?

    public var fraction: Double? {
        guard let completed, let total, completed >= 0, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    public var title: String {
        switch stage {
        case .preparing: return "准备安装环境"
        case .dependencies: return "下载并安装运行组件"
        case .download: return "下载 EmbeddingGemma 2"
        case .verifying: return "验证本地模型"
        case .complete: return "模型安装完成"
        }
    }

    public var detail: String {
        guard let completed, let total, fraction != nil else {
            switch stage {
            case .preparing: return "正在准备安装环境，请稍候…"
            case .dependencies: return "正在准备运行组件，请稍候…"
            case .download: return "正在获取模型下载信息…"
            case .verifying: return "下载已完成，正在检查模型是否可用…"
            case .complete: return "本地模型已通过验证"
            }
        }
        let bytes = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return (stage == .dependencies ? "当前组件：" : "") + "\(bytes) / \(size)"
    }
}

/// Structured progress is separate from diagnostics. Preserve UTF-8 and JSON across arbitrary pipe boundaries.
public struct InstallationProgressDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) -> [ModelInstallationProgress] {
        buffer.append(data)
        var events: [ModelInstallationProgress] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            let prefix = Data("BITCLIPBOARD_INSTALL ".utf8)
            guard line.starts(with: prefix),
                  let event = try? JSONDecoder().decode(ModelInstallationProgress.self, from: line.dropFirst(prefix.count)) else { continue }
            events.append(event)
        }
        // A malformed diagnostic line must not grow memory indefinitely.
        if buffer.count > 1_000_000 { buffer.removeAll() }
        return events
    }
}

public enum ModelInstallationError: LocalizedError {
    case failed
    public var errorDescription: String? { "下载或安装失败，请查看安装日志后重试。" }
}

public enum ModelInstallation {
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
    }

    public static func events(script: URL, runtime: URL, logURL: URL) -> AsyncThrowingStream<ModelInstallationProgress, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let state = ProcessState()
            continuation.onTermination = { reason in
                if case .cancelled = reason { state.cancel() }
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let manager = FileManager.default
                    try manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data().write(to: logURL, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
                    let log = try FileHandle(forWritingTo: logURL)
                    defer { try? log.close() }
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/bin/bash")
                    process.arguments = [script.path, runtime.path]
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try state.start(process)
                    var decoder = InstallationProgressDecoder()
                    while true {
                        let data = pipe.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        try log.write(contentsOf: data)
                        for event in decoder.append(data) { continuation.yield(event) }
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw ModelInstallationError.failed }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
