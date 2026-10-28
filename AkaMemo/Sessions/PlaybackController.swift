import AVFoundation
import AkaMemoCore
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    private(set) var currentChunkID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    var progress: Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }

    var currentTimeText: String {
        SessionFormatting.clockText(currentTime)
    }

    func toggle(chunk: ChunkSummary) {
        if currentChunkID == chunk.chunkID {
            if isPlaying {
                player?.pause()
                isPlaying = false
                stopProgressUpdates()
            } else if let player {
                if player.currentTime >= player.duration - 0.1 {
                    player.currentTime = 0
                }
                player.play()
                isPlaying = true
                startProgressUpdates()
            }
            return
        }
        start(chunk: chunk)
    }

    func seek(to progress: Double) {
        guard let player, duration > 0 else {
            return
        }
        let time = min(max(progress, 0), 1) * duration
        player.currentTime = time
        currentTime = time
    }

    func stop() {
        stopProgressUpdates()
        player?.stop()
        player = nil
        isPlaying = false
        currentChunkID = nil
        currentTime = 0
        duration = 0
        errorMessage = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Starts a chunk, optionally from an absolute position in that chunk.
    func start(chunk: ChunkSummary, atAbsoluteMs: Int64? = nil) {
        stop()
        do {
            let root = try PhonePaths.applicationSupport()
            let url = root.appending(path: chunk.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                errorMessage = String(localized: "playback.error.missing")
                return
            }

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
            guard player.play() else {
                errorMessage = String(localized: "playback.error.play")
                return
            }

            self.player = player
            currentChunkID = chunk.chunkID
            currentTime = 0
            duration = player.duration
            isPlaying = true
            errorMessage = nil
            if let atAbsoluteMs {
                let offset = max(
                    0,
                    Double(atAbsoluteMs - chunk.startedAtMs) / 1_000 - 1.5
                )
                player.currentTime = min(
                    offset,
                    max(0, player.duration - 0.2)
                )
                currentTime = player.currentTime
            }
            startProgressUpdates()
        } catch {
            errorMessage = String(localized: "playback.error.play")
        }
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let player = self.player else {
                    return
                }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    if player.currentTime >= player.duration - 0.1 {
                        player.currentTime = 0
                        self.currentTime = 0
                    }
                    return
                }
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }
}
