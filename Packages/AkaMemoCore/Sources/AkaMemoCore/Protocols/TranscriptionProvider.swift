import Foundation

public struct TranscriptionOptions: Sendable, Codable, Equatable {
    public var language: String?
    public var prefersOnDevice: Bool
    /// Absolute Unix milliseconds of the first audio frame. Providers use it
    /// to return segment timestamps that are absolute, not file-relative.
    public var startedAtMs: Int64?

    public init(
        language: String? = nil,
        prefersOnDevice: Bool = true,
        startedAtMs: Int64? = nil
    ) {
        self.language = language
        self.prefersOnDevice = prefersOnDevice
        self.startedAtMs = startedAtMs
    }
}

public struct SegmentDraft: Sendable, Codable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let confidence: Double?

    public init(startMs: Int64, endMs: Int64, text: String, confidence: Double? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }
}

public struct TranscriptDraft: Sendable, Codable, Equatable {
    public let providerID: String
    public let providerVersion: String
    public let language: String
    public let text: String
    public let segments: [SegmentDraft]

    public init(
        providerID: String,
        providerVersion: String,
        language: String,
        text: String,
        segments: [SegmentDraft]
    ) {
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.language = language
        self.text = text
        self.segments = segments
    }
}

public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var version: String { get }
    var supportedLanguages: [String] { get }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions
    ) async throws -> TranscriptDraft
}
