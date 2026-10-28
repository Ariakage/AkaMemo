#if DEBUG
    import AVFoundation
    import AkaMemoCore
    import Foundation
    import OSLog

    /// Seeds the iPhone app with synthetic chunks for simulator UI testing.
    ///
    /// Enabled only in Debug builds and only when the app is launched with
    /// `-AkaMemoSeedDemoChunks`. Chunks go through `PhoneInboxService.receive`, so
    /// validation, deduplication, archiving, and SwiftData insertion follow the
    /// same path as a real Watch transfer. Audio is generated at runtime as sine
    /// tones; no bundled or real recording is used.
    ///
    /// Chunk and session identifiers are fixed, so relaunching with the flag skips
    /// chunks that already exist instead of duplicating them. Delete the app from
    /// the simulator to start over.
    actor SimulatorFixtureSeeder {
        struct Report: Sendable, Equatable {
            var accepted = 0
            var duplicates = 0
            var rejected = 0
            var skipped = 0
        }

        enum SeedError: Error {
            case invalidPlan
            case bufferAllocationFailed
        }

        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains("-AkaMemoSeedDemoChunks")
        }

        private struct DemoChunk {
            let chunkID: String
            let sequence: Int
            let durationSeconds: Int
            let frequency: Double
        }

        private struct DemoSession {
            let sessionID: String
            let offsetSeconds: TimeInterval
            let chunks: [DemoChunk]
        }

        private static let sessions: [DemoSession] = [
            DemoSession(
                sessionID: "8F14E45F-CEE1-4D3B-9A2F-0B6C7D9E1101",
                offsetSeconds: -90 * 60,
                chunks: [
                    DemoChunk(
                        chunkID: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4101",
                        sequence: 0,
                        durationSeconds: 12,
                        frequency: 440.0
                    ),
                    DemoChunk(
                        chunkID: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4102",
                        sequence: 1,
                        durationSeconds: 12,
                        frequency: 523.25
                    ),
                    DemoChunk(
                        chunkID: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4103",
                        sequence: 2,
                        durationSeconds: 12,
                        frequency: 659.25
                    ),
                    DemoChunk(
                        chunkID: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4104",
                        sequence: 3,
                        durationSeconds: 12,
                        frequency: 783.99
                    ),
                ]
            ),
            DemoSession(
                sessionID: "3C59A7B2-6D84-4F10-8E27-51A9C4D6B202",
                offsetSeconds: -26 * 60 * 60,
                chunks: [
                    DemoChunk(
                        chunkID: "2B3C4D5E-6F7A-4B8C-9D0E-1F2A3B4C4201",
                        sequence: 0,
                        durationSeconds: 9,
                        frequency: 392.0
                    ),
                    DemoChunk(
                        chunkID: "2B3C4D5E-6F7A-4B8C-9D0E-1F2A3B4C4202",
                        sequence: 1,
                        durationSeconds: 9,
                        frequency: 493.88
                    ),
                    DemoChunk(
                        chunkID: "2B3C4D5E-6F7A-4B8C-9D0E-1F2A3B4C4203",
                        sequence: 2,
                        durationSeconds: 9,
                        frequency: 587.33
                    ),
                ]
            ),
            DemoSession(
                sessionID: "7D2E9A41-B5C3-4E68-A0F1-9C4B8D2E3303",
                offsetSeconds: -40 * 60,
                chunks: [
                    DemoChunk(
                        chunkID: "3C4D5E6F-7A8B-4C9D-8E0F-2A3B4C5D4301",
                        sequence: 0,
                        durationSeconds: 6,
                        frequency: 349.23
                    ),
                    DemoChunk(
                        chunkID: "3C4D5E6F-7A8B-4C9D-8E0F-2A3B4C5D4302",
                        sequence: 1,
                        durationSeconds: 6,
                        frequency: 440.0
                    ),
                ]
            ),
        ]

        static var chunkCount: Int {
            sessions.reduce(0) { $0 + $1.chunks.count }
        }

        private let inbox: PhoneInboxService
        private let store: MemoryStore
        private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "storage")

        init(inbox: PhoneInboxService, store: MemoryStore) {
            self.inbox = inbox
            self.store = store
        }

        /// Inserts every demo chunk that is not already stored.
        ///
        /// - Parameter now: session timestamps are relative to this date.
        func seedIfNeeded(now: Date = Date()) async -> Report {
            var report = Report()
            for session in Self.sessions {
                do {
                    try await seed(session: session, now: now, report: &report)
                } catch {
                    report.rejected += session.chunks.count
                    logger.error(
                        "simulator seed failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            logger.info(
                "simulator seed complete: accepted \(report.accepted, privacy: .public), duplicates \(report.duplicates, privacy: .public), rejected \(report.rejected, privacy: .public), skipped \(report.skipped, privacy: .public)"
            )
            return report
        }

        private func seed(
            session: DemoSession,
            now: Date,
            report: inout Report
        ) async throws {
            guard let sessionID = UUID(uuidString: session.sessionID),
                session.chunks.allSatisfy({ UUID(uuidString: $0.chunkID) != nil })
            else {
                throw SeedError.invalidPlan
            }
            let sessionStart = now.addingTimeInterval(session.offsetSeconds)
            var chunkStart = sessionStart

            for chunk in session.chunks {
                defer {
                    chunkStart = chunkStart.addingTimeInterval(
                        TimeInterval(chunk.durationSeconds)
                    )
                }
                guard let chunkID = UUID(uuidString: chunk.chunkID) else {
                    continue
                }
                if try await store.contains(chunkID: chunkID) {
                    report.skipped += 1
                    continue
                }

                do {
                    let fileURL = try makeToneFile(
                        frequency: chunk.frequency,
                        durationSeconds: chunk.durationSeconds
                    )
                    defer { try? FileManager.default.removeItem(at: fileURL) }

                    let data = try Data(contentsOf: fileURL)
                    let startedAtMs = TimeMath.epochMs(chunkStart)
                    let envelope = ChunkTransferEnvelope(
                        chunkID: chunkID,
                        sessionID: sessionID,
                        sessionStartedAtMs: TimeMath.epochMs(sessionStart),
                        sequence: chunk.sequence,
                        startedAtMs: startedAtMs,
                        durationMs: chunk.durationSeconds * 1_000,
                        byteSize: data.count,
                        checksumSHA256: AtomicFileWriter.sha256Hex(data),
                        formatVersion: 1,
                        sampleRate: 44_100,
                        channels: 2,
                        bitRate: 96_000,
                        relativePath:
                            "audio/\(session.sessionID)/\(String(format: "%04d", chunk.sequence))-\(startedAtMs).m4a"
                    )

                    switch await inbox.receive(fileURL: fileURL, envelope: envelope) {
                    case .accepted:
                        report.accepted += 1
                    case .duplicate:
                        report.duplicates += 1
                    case .rejected(let reason):
                        report.rejected += 1
                        logger.error(
                            "simulator seed chunk rejected: \(reason, privacy: .public)"
                        )
                    }
                } catch {
                    report.rejected += 1
                    logger.error(
                        "simulator seed chunk failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        /// Writes a short stereo AAC tone and returns its temporary file URL.
        private func makeToneFile(frequency: Double, durationSeconds: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(
                path: "seed-\(UUID().uuidString).m4a"
            )
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRatePerChannelKey: 96_000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(
                (format.sampleRate * Double(durationSeconds)).rounded()
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                let channels = buffer.floatChannelData
            else {
                throw SeedError.bufferAllocationFailed
            }
            buffer.frameLength = frameCount
            let increment = 2 * Double.pi * frequency / format.sampleRate
            for index in 0..<Int(frameCount) {
                let sample = Float(sin(Double(index) * increment)) * 0.2
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][index] = sample
                }
            }
            try file.write(from: buffer)
            return url
        }
    }
#endif
