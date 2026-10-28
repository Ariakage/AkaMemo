import AkaMemoCore
import Foundation
import OSLog
import WatchConnectivity

/// Receives chunk files from the Watch and sends application-level
/// confirmations. Files are moved out of the system Inbox before any
/// verification work starts.
final class PhoneConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let inbox: PhoneInboxService
    private let processingDirectory: URL
    private let rejectedDirectory: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "transfer")

    init(inbox: PhoneInboxService, applicationSupport: URL) {
        self.inbox = inbox
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
        if let error {
            logger.error(
                "WCSession activation failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let sourceURL = file.fileURL
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
            quarantine(processingURL)
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
}
