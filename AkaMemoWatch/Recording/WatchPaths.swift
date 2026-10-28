import Foundation

enum WatchPaths {
    private static let rootDirectoryName = "AkaMemoWatch"

    static func applicationSupport() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: rootDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func audioRoot() throws -> URL {
        let root = try applicationSupport().appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func sessionDirectory(id: UUID) throws -> URL {
        let directory = try audioRoot().appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Holds chunks while AVAudioRecorder is writing them. The files keep a
    /// `.m4a` extension so the recorder produces an M4A container.
    static func partsDirectory(in sessionDirectory: URL) throws -> URL {
        let directory = sessionDirectory.appending(
            path: ".parts",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func healthFileURL() throws -> URL {
        try applicationSupport().appending(path: "health.json")
    }

    static func locationRoot() throws -> URL {
        let root = try applicationSupport().appending(
            path: "location",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func locationFileURL(sessionID: UUID) throws -> URL {
        try locationRoot().appending(path: "\(sessionID.uuidString).jsonl")
    }
}
