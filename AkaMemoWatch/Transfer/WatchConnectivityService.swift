import AkaMemoCore
import Foundation
import OSLog
import WatchConnectivity

/// Bridges `WCSession` to the persistent transfer queue.
///
/// Callbacks can arrive on any queue; this object holds only a `Sendable`
/// actor reference, so it is safe to pass the instance to the queue.
final class WatchConnectivityService: NSObject, WCSessionDelegate,
    ChunkTransferTransport, BatteryEventTransport, HealthEventTransport,
    DiagnosticsTransport, @unchecked Sendable
{
    private let queue: WatchTransferQueue
    private let deletionHandler: WatchDeletionHandler?
    private let handlerLock = NSLock()
    private var locationSettingHandler: (@Sendable (LocationSetting) -> Void)?
    private var resumeSettingsHandler: (@Sendable (ResumeSettingsCommand) -> Void)?
    private var logHandler: (@Sendable (LogLevel, LogCategory, String, [String: String]) -> Void)?
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "transfer")

    init(
        queue: WatchTransferQueue,
        deletionHandler: WatchDeletionHandler? = nil
    ) {
        self.queue = queue
        self.deletionHandler = deletionHandler
        super.init()
    }

    /// Registered by the view model so a phone-side toggle stops or starts
    /// location collection immediately.
    func setLocationSettingHandler(
        _ handler: @escaping @Sendable (LocationSetting) -> Void
    ) {
        handlerLock.lock()
        locationSettingHandler = handler
        handlerLock.unlock()
    }

    func setResumeSettingsHandler(
        _ handler: @escaping @Sendable (ResumeSettingsCommand) -> Void
    ) {
        handlerLock.lock()
        resumeSettingsHandler = handler
        handlerLock.unlock()
    }

    /// Registered by the view model to forward connection/transfer events to
    /// the Watch diagnostics buffer.
    func setLogHandler(
        _ handler:
            @escaping @Sendable (
                LogLevel, LogCategory, String, [String: String]
            ) -> Void
    ) {
        handlerLock.lock()
        logHandler = handler
        handlerLock.unlock()
    }

    private nonisolated func emitLog(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        _ metadata: [String: String] = [:]
    ) {
        handlerLock.lock()
        let handler = logHandler
        handlerLock.unlock()
        handler?(level, category, message, metadata)
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
            Task { await queue.activate(with: self) }
            emitLog(.info, .transfer, "watch session activated")
        } else if let error {
            logger.error(
                "WCSession activation failed: \(String(describing: error), privacy: .public)"
            )
            emitLog(
                .error,
                .transfer,
                "watch session activation failed",
                ["errorCode": "activationFailed"]
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        var chunkID: UUID?
        if let metadata = fileTransfer.file.metadata,
            let rawChunkID = metadata["chunkID"] as? String
        {
            chunkID = UUID(uuidString: rawChunkID)
        }
        let code: String? = error.map { String(describing: $0) }
        emitLog(
            error == nil ? .info : .warning,
            .transfer,
            "chunk transfer finished",
            ["errorCode": error == nil ? "none" : "transferFailed"]
        )
        Task {
            await queue.handleTransferFinished(chunkID: chunkID, errorCode: code)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleIncoming(userInfo)
        handleAcknowledgement(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
        handleAcknowledgement(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(applicationContext)
    }

    nonisolated func transferFile(at url: URL, metadata: [String: String]) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            return false
        }
        let info: [String: Any] = metadata.reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value
        }
        _ = session.transferFile(url, metadata: info)
        return true
    }

    private nonisolated func handleIncoming(_ info: [String: Any]) {
        switch info["type"] as? String {
        case "deletion":
            guard
                let payload = info[DeletionCommand.metadataKey] as? String,
                let command = try? DeletionCommand.decode(fromJSON: payload),
                let deletionHandler
            else {
                return
            }
            Task {
                await deletionHandler.apply(command)
                sendDeletionAck(tombstoneID: command.tombstoneID)
            }
        case "locationSetting":
            guard
                let payload = info[LocationSetting.metadataKey] as? String,
                let setting = try? LocationSetting.decode(fromJSON: payload)
            else {
                return
            }
            handlerLock.lock()
            let handler = locationSettingHandler
            handlerLock.unlock()
            handler?(setting)
        case "resumeSettings":
            guard
                let payload = info[ResumeSettingsCommand.metadataKey] as? String,
                let command = try? ResumeSettingsCommand.decode(
                    fromJSON: payload
                )
            else {
                return
            }
            handlerLock.lock()
            let handler = resumeSettingsHandler
            handlerLock.unlock()
            handler?(command)
        default:
            return
        }
    }

    nonisolated func updateHealthContext(
        _ event: RecordingHealthEvent
    ) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? event.jsonString()
        else {
            return false
        }
        do {
            try session.updateApplicationContext([
                "type": "health",
                RecordingHealthEvent.metadataKey: payload,
            ])
            return true
        } catch {
            return false
        }
    }

    nonisolated func sendHealthEvent(
        _ event: RecordingHealthEvent
    ) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? event.jsonString()
        else {
            return false
        }
        let info: [String: Any] = [
            "type": "health",
            RecordingHealthEvent.metadataKey: payload,
        ]
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    nonisolated func sendTrack(
        fileURL: URL,
        envelope: TrackTransferEnvelope
    ) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? envelope.jsonString()
        else {
            return false
        }
        _ = session.transferFile(
            fileURL,
            metadata: [
                "type": "track",
                TrackTransferEnvelope.metadataKey: payload,
            ]
        )
        return true
    }

    nonisolated func sendDiagnostics(_ batch: DiagnosticsBatch) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            batch.isValid,
            let payload = try? batch.jsonString()
        else {
            return false
        }
        session.transferUserInfo([
            "type": "diagnostics",
            DiagnosticsBatch.metadataKey: payload,
        ])
        return true
    }

    nonisolated func sendBatteryEvent(_ event: BatteryEvent) -> Bool {
        guard WCSession.isSupported() else {
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated,
            let payload = try? event.jsonString()
        else {
            return false
        }
        let info: [String: Any] = [
            "type": "battery",
            BatteryEvent.metadataKey: payload,
        ]
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    private nonisolated func sendDeletionAck(tombstoneID: UUID) {
        let info: [String: Any] = [
            "type": "deletionAck",
            "tombstoneID": tombstoneID.uuidString,
        ]
        let session = WCSession.default
        session.transferUserInfo(info)
        if session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
    }

    private nonisolated func handleAcknowledgement(_ info: [String: Any]) {
        guard info["type"] as? String == "chunkConfirmed",
            let rawChunkID = info["chunkID"] as? String,
            let chunkID = UUID(uuidString: rawChunkID),
            let checksum = info["checksum"] as? String
        else {
            return
        }
        Task {
            await queue.handleConfirmation(chunkID: chunkID, checksum: checksum)
        }
    }
}
