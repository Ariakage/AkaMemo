@preconcurrency import AVFoundation
import AkaMemoCore
import Foundation
import OSLog
@preconcurrency import Speech

/// On-device transcription using Apple Speech.
///
/// Audio is downmixed to mono, resampled to 16 kHz (ADR-0011), and split into
/// at most 50-second windows. Every request sets
/// `requiresOnDeviceRecognition = true`; there is no cloud fallback.
actor AppleSpeechTranscriptionProvider: TranscriptionProvider {
    nonisolated let id = "apple-speech"
    nonisolated let version: String
    nonisolated let supportedLanguages: [String]

    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "transcription"
    )

    init() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.version = "ios-\(osVersion.majorVersion).\(osVersion.minorVersion)"

        var languages: [String] = []
        let supportedLocales = SFSpeechRecognizer.supportedLocales()
        for identifier in Locale.preferredLanguages {
            if supportedLocales.contains(Locale(identifier: identifier)) {
                languages.append(identifier)
            }
        }
        for fallback in ["zh-Hans", "en-US"] where !languages.contains(fallback) {
            languages.append(fallback)
        }
        self.supportedLanguages = languages
    }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions
    ) async throws -> TranscriptDraft {
        try await ensureAuthorized()
        let resolved = try resolveRecognizer(
            preferredLanguage: options.language
        )
        let converted: (url: URL, durationMs: Int64)
        do {
            converted = try convertToMono16k(audioURL: audioURL)
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        defer { try? FileManager.default.removeItem(at: converted.url) }

        let windows = TranscriptionWindowPlanner.plan(
            durationMs: converted.durationMs
        )
        guard !windows.isEmpty else {
            throw TranscriptionFailure(code: .decodeFailed)
        }

        let chunkStartMs = options.startedAtMs ?? 0
        var segments: [SegmentDraft] = []
        for window in windows {
            let output = try await recognizeWindow(
                fileURL: converted.url,
                window: window,
                recognizer: resolved.recognizer
            )
            for segment in output.segments {
                let start = TranscriptionWindowPlanner.absoluteStartMs(
                    chunkStartedAtMs: chunkStartMs,
                    windowOffsetMs: window.offsetMs,
                    segmentOffsetMs: segment.startMs
                )
                let end = max(
                    start + (segment.endMs - segment.startMs),
                    start
                )
                segments.append(
                    SegmentDraft(
                        startMs: start,
                        endMs: end,
                        text: segment.text,
                        confidence: segment.confidence
                    )
                )
            }
        }

        let text =
            segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info(
            "transcribed \(windows.count, privacy: .public) window(s), \(segments.count, privacy: .public) segment(s)"
        )
        return TranscriptDraft(
            providerID: id,
            providerVersion: version,
            language: resolved.language,
            text: text,
            segments: segments
        )
    }

    private func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw TranscriptionFailure(code: .permissionDenied)
            }
        default:
            throw TranscriptionFailure(code: .permissionDenied)
        }
    }

    private func resolveRecognizer(
        preferredLanguage: String?
    ) throws -> (recognizer: SFSpeechRecognizer, language: String) {
        var candidates: [String] = []
        if let preferredLanguage {
            candidates.append(preferredLanguage)
        }
        candidates.append(contentsOf: supportedLanguages)
        for identifier in candidates {
            guard
                let recognizer = SFSpeechRecognizer(
                    locale: Locale(identifier: identifier)
                ), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
            else {
                continue
            }
            return (recognizer, identifier)
        }
        throw TranscriptionFailure(code: .engineUnavailable)
    }

    /// Converts any supported input to 16 kHz mono linear PCM.
    private func convertToMono16k(
        audioURL: URL
    ) throws -> (url: URL, durationMs: Int64) {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        guard inputFile.length > 0 else {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        guard
            let targetFormat = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1
            ),
            let converter = AVAudioConverter(
                from: inputFile.processingFormat,
                to: targetFormat
            )
        else {
            throw TranscriptionFailure(code: .unsupportedFormat)
        }

        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "transcribe-\(UUID().uuidString).caf"
        )
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
        } catch {
            throw TranscriptionFailure(code: .decodeFailed)
        }

        let inputCapacity: AVAudioFrameCount = 4_096
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: inputCapacity
            )
        else {
            throw TranscriptionFailure(code: .decodeFailed)
        }

        var totalFrames: AVAudioFramePosition = 0
        while true {
            do {
                try inputFile.read(into: inputBuffer)
            } catch {
                throw TranscriptionFailure(code: .decodeFailed)
            }
            if inputBuffer.frameLength == 0 {
                break
            }

            let inputState = OneShotInput()
            while true {
                guard
                    let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: targetFormat,
                        frameCapacity: inputCapacity
                    )
                else {
                    throw TranscriptionFailure(code: .decodeFailed)
                }
                var conversionError: NSError?
                let status = converter.convert(
                    to: outputBuffer,
                    error: &conversionError
                ) { _, outStatus in
                    if inputState.used {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputState.used = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                if conversionError != nil {
                    throw TranscriptionFailure(code: .decodeFailed)
                }
                if outputBuffer.frameLength > 0 {
                    do {
                        try outputFile.write(from: outputBuffer)
                    } catch {
                        throw TranscriptionFailure(code: .decodeFailed)
                    }
                    totalFrames += AVAudioFramePosition(
                        outputBuffer.frameLength
                    )
                }
                if status == .error {
                    throw TranscriptionFailure(code: .decodeFailed)
                }
                if status != .haveData {
                    break
                }
            }
        }

        // Drain the resampler tail: returning no buffer with `.endOfStream`
        // asks the converter to flush anything it still holds.
        while true {
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: inputCapacity
                )
            else {
                throw TranscriptionFailure(code: .decodeFailed)
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if conversionError != nil {
                throw TranscriptionFailure(code: .decodeFailed)
            }
            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw TranscriptionFailure(code: .decodeFailed)
                }
                totalFrames += AVAudioFramePosition(outputBuffer.frameLength)
            }
            if status != .haveData {
                break
            }
        }

        guard totalFrames > 0 else {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        let durationMs = Int64(
            (Double(totalFrames) / 16_000 * 1_000).rounded()
        )
        return (outputURL, durationMs)
    }

    private struct OffsetSegment: Sendable {
        let startMs: Int64
        let endMs: Int64
        let text: String
        let confidence: Double?
    }

    private struct RecognitionOutput: Sendable {
        let segments: [OffsetSegment]
    }

    private func recognizeWindow(
        fileURL: URL,
        window: TranscriptionWindow,
        recognizer: SFSpeechRecognizer
    ) async throws -> RecognitionOutput {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(
            Double(window.offsetMs) / 1_000 * format.sampleRate
        )
        let requestedFrames = AVAudioFrameCount(
            Double(window.durationMs) / 1_000 * format.sampleRate
        )
        file.framePosition = startFrame
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: requestedFrames
            )
        else {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        do {
            try file.read(into: buffer, frameCount: requestedFrames)
        } catch {
            throw TranscriptionFailure(code: .decodeFailed)
        }
        if buffer.frameLength == 0 {
            return RecognitionOutput(segments: [])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            let gate = RecognitionGate()
            recognizer.recognitionTask(with: request) {
                result, error in
                if error != nil {
                    if gate.finish() {
                        continuation.resume(
                            throwing: TranscriptionFailure(
                                code: .engineUnavailable
                            )
                        )
                    }
                    return
                }
                guard let result, result.isFinal else {
                    return
                }
                let output = Self.makeOutput(result: result)
                if gate.finish() {
                    continuation.resume(returning: output)
                }
            }
            request.append(buffer)
            request.endAudio()
        }
    }

    private nonisolated static func makeOutput(
        result: SFSpeechRecognitionResult
    ) -> RecognitionOutput {
        var segments: [OffsetSegment] = []
        for segment in result.bestTranscription.segments {
            let text = segment.substring.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                continue
            }
            let startMs = Int64((segment.timestamp * 1_000).rounded())
            let endMs =
                startMs
                + Int64((segment.duration * 1_000).rounded())
            let confidence =
                segment.confidence > 0
                ? Double(segment.confidence)
                : nil
            segments.append(
                OffsetSegment(
                    startMs: startMs,
                    endMs: max(endMs, startMs),
                    text: text,
                    confidence: confidence
                )
            )
        }
        return RecognitionOutput(segments: segments)
    }
}

/// Lets the converter receive one input buffer per call.
private final class OneShotInput: @unchecked Sendable {
    var used = false
}

/// Guards a checked continuation against multiple resumptions.
private final class RecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            return false
        }
        finished = true
        return true
    }
}
