import AkaMemoCore
import Foundation
import OSLog
import WatchConnectivity

/// Receives chunk files from the Watch and sends application-level
/// confirmations. Files are moved out of the system Inbox before any
/// verification work starts.
final class PhoneConnectivityService: NSObject, WCSessionDelegate, DeletionCommandSending,
    LocationSettingSending, ResumeSettingsSending, @unchecked Sendable
{
    private let inbox: PhoneInboxService
    private let deletionStore: DeletionStore?
    private let trackImporter: TrackImporter?
    private let batteryEventHandler: (@Sendable (BatteryEvent) -> Void)?
    private let healthEventHandler: (@Sendable (RecordingHealthEvent) -> Void)?
    private let diagnosticsBatchHandler: (@Sendable (DiagnosticsBatch) -> Void)?
    private let activationHandler: (@Sendable () -> Void)?
    private let processingDirectory: URL
    private let rejectedDirectory: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "transfer")

    init(
        inbox: PhoneInboxService,
        applicationSupport: URL,
        deletionStore: DeletionStore? = nil,
        trackImporter: TrackImporter? = nil,
        batteryEventHandler: (@Sendable (BatteryEvent) -> Void)? = nil,
        healthEventHandler: (@Sendable (RecordingHealthEvent) -> Void)? = nil,
        diagnosticsBatchHandler: (@Sendable (DiagnosticsBatch) -> Void)? = nil,
        activationHandler: (@Sendable () -> Void)? = nil
    ) {
        self.inbox = inbox
        self.deletionStore = deletionStore
        self.trackImporter = trackImporter
        self.batteryEventHandler = batteryEventHandler
        self.healthEventHandler = healthEventHandler
        self.diagnosticsBatchHandler = diagnosticsBatchHandler
        self.activationHandler = activationHandler
        self.processingDirectory = applicationSupport.appending(
            path: "inbox-processing",
            directoryHint: .isDirectory
        )
        self.rejectedDirectory = applicationSupport.appending(
            path: "inbox-rejected",
            directoryHint: .isDirectory
        )
        super.init()
        try? fileManager.createDirectory(
            at: processingDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: rejectedDirectory,
            withIntermediateDirectories: true
        )
    }

    func activate() {
        guard WCSession.isSupported() else {
            logger.warning("WatchConnectivity is not supported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            Task {
                await resendDeletions()
            }
            activationHandler?()
        }
        if let error {
            logger.error(
                "WCSession activation failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else {
            return
        }
        Task {
            await resendDeletions()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let sourceURL = file.fileURL
        if let trackPayload = file.metadata?[
            TrackTransferEnvelope.metadataKey
        ] as? String {
            Task {
                await handleReceivedTrackFile(
                    sourceURL: sourceURL,
                    payload: trackPayload
                )
            }
            return
        }
        let payload = file.metadata?[ChunkTransferEnvelope.metadataKey] as? String
        Task {
            await handleReceivedFile(sourceURL: sourceURL, payload: payload)
        }
    }

    private func handleReceivedFile(sourceURL: URL, payload: String?) async {
        let processingURL = processingDirectory.appending(
            path: UUID().uuidString + ".m4a"
        )
        do {
            try fileManager.moveItem(at: sourceURL, to: processingURL)
        } catch {
            logger.error(
                "could not move inbox file: \(String(describing: error), privacy: .public)"
            )
            return
        }

        guard let payload,
            let envelope = try? ChunkTransferEnvelope.decode(fromJSON: payload)
        else {
            quarantine(processingURL)
            return
        }

        let result = await inbox.receive(fileURL: processingURL, envelope: envelope)
        switch result {
        case .accepted, .duplicate:
            sendAcknowledgement(
                chunkID: envelope.chunkID,
                checksum: envelope.checksumSHA256
            )
        case .rejected(let reason):
            logger.error("chunk rejected: \(reason, privacy: .public)")
            if reason.hasPrefix("deleted") {
                try? fileManager.removeItem(at: processingURL)
                Task {
                    await resendDeletionForRejectedChunk(
                        chunkID: envelope.chunkID,
                        sessionID: envelope.sessionID
                    )
                }
            } else {
                quarantine(processingURL)
            }
        }
    }

    private func handleReceivedTrackFile(
        sourceURL: URL,
        payload: String
    ) async {
        guard let trackImporter else {
            return
        }
        let processingURL = processingDirectory.appending(
            path: UUID().uuidString + ".jsonl"
        )
        do {
            try fileManager.moveItem(at: sourceURL, to: processingURL)
        } catch {
            return
        }
        guard
            let envelope = try? TrackTransferEnvelope.decode(
                fromJSON: payload
            )
        else {
            quarantine(processingURL)
            return
        }
        let result = await trackImporter.importFile(
            at: processingURL,
            envelope: envelope
        )
        switch result {
        case .accepted, .duplicate:
            sendTrackAcknowledgement(trackID: envelope.trackID)
        case .rejected(let reason):
            logger.error(
                "track rejected: \(reason, privacy: .public)"
            )
            if fileManager.fileExists(atPath: processingURL.path) {
                quarantine(processingURL)
            }
            Task {
                await resendDeletionForRejectedTrack(
                    sessionID: envelope.sessionID
                )
            }
        }
    }

    private func sendTrackAcknowledgement(trackID: UUID) {
        let info: [String: Any] = [
            "type": "trackImported",
            "trackID": trackID.uuidString,
        ]
        let session = WCSession.default
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
    }

    private func quarantine(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let destination = rejectedDirectory.appending(
            path: UUID().uuidString + ".m4a"
        )
        try? fileManager.moveItem(at: url, to: destination)
    }

    private func sendAcknowledgement(chunkID: UUID, checksum: String) {
        let info: [String: Any] = [
            "type": "chunkConfirmed",
            "chunkID": chunkID.uuidString,
            "checksum": checksum,
        ]
        let session = WCSession.default
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - Deletion

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleIncoming(userInfo)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handleIncoming(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(applicationContext)
    }

    private nonisolated func handleIncoming(_ info: [String: Any]) {
        if info["type"] as? String == "diagnostics",
            let payload = info[DiagnosticsBatch.metadataKey] as? String,
            let batch = try? DiagnosticsBatch.decode(fromJSON: payload),
            batch.isValid
        {
            diagnosticsBatchHandler?(batch)
            return
        }
        if info["type"] as? String == "health",
            let payload = info[RecordingHealthEvent.metadataKey] as? String,
            let event = try? RecordingHealthEvent.decode(fromJSON: payload)
        {
            healthEventHandler?(event)
            return
        }
        if info["type"] as? String == "battery",
            let payload = info[BatteryEvent.metadataKey] as? String,
            let event = try? BatteryEvent.decode(fromJSON: payload)
        {
            batteryEventHandler?(event)
            return
        }
        guard info["type"] as? String == "deletionAck",
            let rawID = info["tombstoneID"] as? String,
            let tombstoneID = UUID(uuidString: rawID)
        else {
            return
        }
        Task {
            try? await deletionStore?.markAcknowledged(
                tombstoneID: tombstoneID
            )
        }
    }

    nonisolated func sendDeletion(_ command: DeletionCommand) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? command.jsonString()
        else {
            return false
        }
        let info: [String: Any] = [
            "type": "deletion",
            DeletionCommand.metadataKey: payload,
        ]
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    nonisolated func sendLocationSetting(_ setting: LocationSetting) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? setting.jsonString()
        else {
            return false
        }
        do {
            try session.updateApplicationContext([
                "type": "locationSetting",
                LocationSetting.metadataKey: payload,
            ])
            return true
        } catch {
            logger.error(
                "location setting context failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    nonisolated func sendResumeSettings(
        _ command: ResumeSettingsCommand
    ) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? command.jsonString()
        else {
            return false
        }
        do {
            try session.updateApplicationContext([
                "type": "resumeSettings",
                ResumeSettingsCommand.metadataKey: payload,
            ])
            return true
        } catch {
            logger.error(
                "resume setting context failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private func resendDeletions() async {
        guard let deletionStore else {
            return
        }
        let commands =
            (try? await deletionStore.unacknowledgedCommands()) ?? []
        for command in commands {
            _ = sendDeletion(command)
        }
    }

    private func resendDeletionForRejectedChunk(
        chunkID: UUID,
        sessionID: UUID
    ) async {
        guard let deletionStore else {
            return
        }
        if let command = try? await deletionStore.commandForRejectedChunk(
            chunkID: chunkID,
            sessionID: sessionID
        ) {
            _ = sendDeletion(command)
        }
    }

    private func resendDeletionForRejectedTrack(sessionID: UUID) async {
        guard let deletionStore else {
            return
        }
        if let command = try? await deletionStore.commandForRejectedTrack(
            sessionID: sessionID
        ) {
            _ = sendDeletion(command)
        }
    }
}
