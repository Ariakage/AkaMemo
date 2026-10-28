import Foundation

/// A batch of Watch log entries forwarded to the iPhone.
///
/// Batches are sent with `transferUserInfo`, so they survive a temporarily
/// unreachable phone; the Watch keeps unsent entries in its bounded buffer.
public struct DiagnosticsBatch: Codable, Sendable, Equatable {
    public static let metadataKey = "akamemo.diagnostics"
    public static let maximumEntryCount = 50

    public let batchID: UUID
    public let sentAtMs: Int64
    public let entries: [LogEntry]

    public init(
        batchID: UUID = UUID(),
        entries: [LogEntry],
        sentAtMs: Int64
    ) {
        self.batchID = batchID
        self.entries = entries
        self.sentAtMs = sentAtMs
    }

    public var isValid: Bool {
        !entries.isEmpty && entries.count <= Self.maximumEntryCount
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DiagnosticsBatchError.invalidEncoding
        }
        return string
    }

    public static func decode(fromJSON string: String) throws -> DiagnosticsBatch {
        guard let data = string.data(using: .utf8) else {
            throw DiagnosticsBatchError.invalidEncoding
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DiagnosticsBatch.self, from: data)
    }
}

public enum DiagnosticsBatchError: Error, Equatable, Sendable {
    case invalidEncoding
}
