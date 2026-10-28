import XCTest

@testable import AkaMemoCore

private struct JSONPayload: Codable, Sendable {
    let alpha: Int
    let when: Date
}

final class AtomicFileWriterTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoCoreTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWritePublishesSealedFileAndRemovesPart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AtomicFileWriter(directory: directory)
        let data = Data("synthetic audio".utf8)
        let name = "0000-1700000000000.m4a"

        let result = try await writer.write(data, fileName: name)

        XCTAssertEqual(result.byteSize, data.count)
        XCTAssertEqual(result.checksumSHA256, AtomicFileWriter.sha256Hex(data))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appending(path: name + ".part").path)
        )
        XCTAssertEqual(try Data(contentsOf: result.url), data)
    }

    func testWriteReplacesStalePartFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AtomicFileWriter(directory: directory)
        let name = "0000-1700000000000.m4a"
        try Data("stale".utf8).write(to: directory.appending(path: name + ".part"))
        let data = Data("fresh".utf8)

        let result = try await writer.write(data, fileName: name)

        XCTAssertEqual(try Data(contentsOf: result.url), data)
    }

    func testWriteRefusesToOverwriteSealedFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AtomicFileWriter(directory: directory)
        let name = "0000-1700000000000.m4a"
        let original = Data("original".utf8)
        let first = try await writer.write(original, fileName: name)

        do {
            _ = try await writer.write(Data("replacement".utf8), fileName: name)
            XCTFail("expected destinationAlreadyExists")
        } catch let error as AtomicFileWriter.WriteError {
            XCTAssertEqual(error, .destinationAlreadyExists(name))
        }

        XCTAssertEqual(try Data(contentsOf: first.url), original)
    }

    func testWriteCanAtomicallyReplaceMutableState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AtomicFileWriter(directory: directory)
        let name = "manifest.json"
        _ = try await writer.write(Data("first".utf8), fileName: name)

        let replacement = Data("second".utf8)
        let result = try await writer.write(replacement, fileName: name, overwrite: true)

        XCTAssertEqual(try Data(contentsOf: result.url), replacement)
        XCTAssertEqual(result.checksumSHA256, AtomicFileWriter.sha256Hex(replacement))
    }

    func testWriteJSONSortsKeysAndUsesMilliseconds() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AtomicFileWriter(directory: directory)
        let payload = JSONPayload(alpha: 2, when: Date(timeIntervalSince1970: 1))

        let result = try await writer.writeJSON(payload, fileName: "0000-1000.json")
        let text = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertEqual(text, "{\"alpha\":2,\"when\":1000}")
    }

    func testChecksumMatchesKnownSHA256() {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            AtomicFileWriter.sha256Hex(data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
