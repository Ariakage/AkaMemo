import CryptoKit
import Foundation

/// Serializes chunk writes and publishes files atomically.
///
/// The write sequence is `.part` → fsync → rename. A crash leaves the `.part`
/// file for the launch scanner; a sealed name is never produced from a
/// half-written file.
public actor AtomicFileWriter {
    public struct WrittenFile: Sendable, Equatable {
        public let url: URL
        public let byteSize: Int
        public let checksumSHA256: String

        public init(url: URL, byteSize: Int, checksumSHA256: String) {
            self.url = url
            self.byteSize = byteSize
            self.checksumSHA256 = checksumSHA256
        }
    }

    public enum WriteError: Error, Equatable, Sendable {
        case destinationAlreadyExists(String)
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL) {
        self.directory = directory
        self.fileManager = .default
    }

    /// Writes `data` to `fileName` through a `.part` file and returns the
    /// sealed file's size and SHA-256 checksum.
    ///
    /// By default a sealed destination is never overwritten, so a repeated
    /// finalize cannot corrupt an earlier chunk. Pass `overwrite: true` for
    /// mutable state such as `manifest.json` or a health snapshot.
    public func write(
        _ data: Data,
        fileName: String,
        overwrite: Bool = false
    ) throws -> WrittenFile {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let finalURL = directory.appending(path: fileName)
        let partURL = directory.appending(path: fileName + ChunkFileSuffix.part.rawValue)
        let destinationExists = fileManager.fileExists(atPath: finalURL.path)

        guard !destinationExists || overwrite else {
            throw WriteError.destinationAlreadyExists(fileName)
        }
        if fileManager.fileExists(atPath: partURL.path) {
            try fileManager.removeItem(at: partURL)
        }

        try data.write(to: partURL, options: writingOptions)
        try synchronizeFile(at: partURL)

        let checksum = Self.sha256Hex(data)
        do {
            if destinationExists {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: partURL)
            } else {
                try fileManager.moveItem(at: partURL, to: finalURL)
            }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
        applySealedFileProtection(at: finalURL)

        return WrittenFile(url: finalURL, byteSize: data.count, checksumSHA256: checksum)
    }

    /// Encodes a JSON sidecar with sorted keys and writes it atomically.
    public func writeJSON<T: Encodable & Sendable>(
        _ value: T,
        fileName: String,
        overwrite: Bool = false
    ) throws -> WrittenFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        return try write(data, fileName: fileName, overwrite: overwrite)
    }

    public nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private var writingOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS)
            return [.completeFileProtectionUnlessOpen]
        #else
            return []
        #endif
    }

    private func applySealedFileProtection(at url: URL) {
        #if os(iOS) || os(watchOS) || os(tvOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }
}
