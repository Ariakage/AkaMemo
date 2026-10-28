import Foundation

/// JSONL diagnostics file log with daily paths, 5 MB rotation, and 7-day
/// retention. All work is serialized by the actor.
public actor DiagnosticsFileLog {
    public enum FileLogError: Error, Equatable, Sendable {
        case writeFailed
    }

    private let root: URL
    private let maxFileBytes: Int
    private let retentionDays: Int
    private let fileManager = FileManager.default
    private var lastPurgeAt: Date = .distantPast

    public init(
        root: URL,
        maxFileBytes: Int = 5 * 1024 * 1024,
        retentionDays: Int = 7
    ) {
        self.root = root
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.retentionDays = max(1, retentionDays)
    }

    public func append(_ entry: LogEntry, now: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(entry)
        data.append(0x0A)

        let directory = dayDirectory(for: now)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appending(path: "diagnostics.jsonl")
        if let size = try? fileManager.attributesOfItem(
            atPath: fileURL.path
        )[.size] as? NSNumber,
            size.intValue + data.count > maxFileBytes
        {
            let rotated = directory.appending(
                path: "diagnostics-\(TimeMath.epochMs(now)).jsonl"
            )
            try? fileManager.moveItem(at: fileURL, to: rotated)
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
            applyProtection(to: fileURL)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw FileLogError.writeFailed
        }
        purgeIfNeeded(now: now)
    }

    public func clear() throws {
        let logsRoot = root.appending(path: "logs", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: logsRoot.path) else {
            return
        }
        try fileManager.removeItem(at: logsRoot)
        lastPurgeAt = .distantPast
    }

    public func fileURLs() -> [URL] {
        let logsRoot = root.appending(path: "logs", directoryHint: .isDirectory)
        guard
            let enumerator = fileManager.enumerator(
                at: logsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func dayDirectory(for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return root.appending(
            path: "logs/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))",
            directoryHint: .isDirectory
        )
    }

    private func purgeIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastPurgeAt) > 3_600 else {
            return
        }
        lastPurgeAt = now
        let cutoff = now.addingTimeInterval(
            -Double(retentionDays) * 24 * 60 * 60
        )
        let logsRoot = root.appending(path: "logs", directoryHint: .isDirectory)
        guard
            let enumerator = fileManager.enumerator(
                at: logsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        for case let url as URL in enumerator {
            guard
                let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            else {
                continue
            }
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func applyProtection(to url: URL) {
        #if os(iOS) || os(watchOS)
            try? fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: url.path
            )
        #endif
    }
}
