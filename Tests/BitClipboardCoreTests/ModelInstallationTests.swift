import XCTest
@testable import BitClipboardCore

final class ModelInstallationTests: XCTestCase {
    func testProgressSurvivesSplitUTF8AndIgnoresDiagnostics() throws {
        var decoder = InstallationProgressDecoder()
        let output = Data("diagnostic\nBITCLIPBOARD_INSTALL {\"stage\":\"download\",\"completed\":50,\"total\":100,\"filename\":\"模型.bin\"}\nBITCLIPBOARD_INSTALL invalid\n".utf8)
        var events: [ModelInstallationProgress] = []
        for byte in output { events += decoder.append(Data([byte])) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fraction, 0.5)
        XCTAssertEqual(events[0].filename, "模型.bin")
        XCTAssertEqual(events[0].title, "下载 EmbeddingGemma 2")
    }

    func testUnknownTotalsAreIndeterminateAndProgressIsBounded() throws {
        func event(_ completed: Int, _ total: Int) throws -> ModelInstallationProgress {
            try JSONDecoder().decode(ModelInstallationProgress.self,
                                     from: Data("{\"stage\":\"dependencies\",\"completed\":\(completed),\"total\":\(total)}".utf8))
        }
        XCTAssertNil(try event(0, 0).fraction)
        XCTAssertNil(try event(-1, 100).fraction)
        XCTAssertEqual(try event(150, 100).fraction, 1)
        XCTAssertTrue(try event(50, 100).detail.hasPrefix("当前组件："))
    }

    func testInstallerStreamsProgressBeforeFinishingAndWritesPrivateLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("setup.sh"), log = directory.appendingPathComponent("setup.log")
        try """
        echo 'BITCLIPBOARD_INSTALL {"stage":"preparing"}'
        echo 'diagnostic' >&2
        echo 'BITCLIPBOARD_INSTALL {"stage":"download","completed":25,"total":100}'
        # Wait for the consumer to acknowledge progress; a runner buffering until exit would hang.
        for attempt in {1..100}; do
            if [[ -e "$1/ack" ]]; then
                echo 'BITCLIPBOARD_INSTALL {"stage":"complete"}'
                exit 0
            fi
            sleep 0.02
        done
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        var events: [ModelInstallationProgress] = []
        for try await progress in ModelInstallation.events(script: script, runtime: directory, logURL: log) {
            events.append(progress)
            if progress.stage == .download { try Data().write(to: directory.appendingPathComponent("ack")) }
        }
        XCTAssertEqual(events.map(\.stage), [.preparing, .download, .complete])
        XCTAssertEqual(events[1].fraction, 0.25)
        XCTAssertTrue(try String(contentsOf: log).contains("diagnostic"))
        let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDownloadFailureRetainsLastProgressAndReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("setup.sh")
        try """
        echo 'BITCLIPBOARD_INSTALL {"stage":"download","completed":40,"total":100}'
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        var last: ModelInstallationProgress?
        do {
            for try await event in ModelInstallation.events(script: script, runtime: directory, logURL: directory.appendingPathComponent("log")) { last = event }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is ModelInstallationError) }
        XCTAssertEqual(last?.fraction, 0.4)
    }
}
