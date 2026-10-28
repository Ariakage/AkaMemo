import AkaMemoCore
import XCTest

@testable import AkaMemo

final class AppDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoDiagnosticsAppTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        suiteName = "AkaMemoDiagnosticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDebugIsGatedUntilEnabled() async {
        let diagnostics = AppDiagnostics(
            root: root,
            subsystem: "test",
            defaultsSuiteName: suiteName
        )

        await diagnostics.log(
            level: .debug,
            category: .ui,
            message: "hidden"
        )
        let before = await diagnostics.snapshot()
        XCTAssertTrue(before.isEmpty)

        await diagnostics.setDebugEnabled(true)
        await diagnostics.log(
            level: .debug,
            category: .ui,
            message: "visible"
        )
        let after = await diagnostics.snapshot()
        XCTAssertEqual(after.map(\.message), ["visible"])
    }

    func testStreamReceivesEntryAndExportContainsIt() async {
        let diagnostics = AppDiagnostics(
            root: root,
            subsystem: "test",
            defaultsSuiteName: suiteName
        )
        let stream = await diagnostics.stream()
        await diagnostics.log(
            level: .info,
            category: .transfer,
            message: "chunk accepted",
            metadata: ["chunkSeq": "1"]
        )

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received?.message, "chunk accepted")
        XCTAssertEqual(received?.metadata["chunkSeq"], "1")

        let export = await diagnostics.exportJSONL()
        XCTAssertTrue(export.contains("chunk accepted"))

        let fileManager = FileManager.default
        let logsRoot = root.appending(path: "logs")
        let enumerator = fileManager.enumerator(at: logsRoot, includingPropertiesForKeys: nil)
        var sawJSONL = false
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl" {
                sawJSONL = true
            }
        }
        XCTAssertTrue(sawJSONL)
    }

    func testClearRemovesBuffer() async {
        let diagnostics = AppDiagnostics(
            root: root,
            subsystem: "test",
            defaultsSuiteName: suiteName
        )
        await diagnostics.log(
            level: .warning,
            category: .storage,
            message: "deletion failed",
            metadata: ["errorCode": "deleteFailed"]
        )
        await diagnostics.clear()
        let snapshot = await diagnostics.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let export = await diagnostics.exportJSONL()
        XCTAssertTrue(export.isEmpty)
    }
}
