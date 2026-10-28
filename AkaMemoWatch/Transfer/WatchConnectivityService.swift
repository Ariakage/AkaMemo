import AkaMemoCore
import Foundation
import OSLog
import WatchConnectivity

/// Bridges `WCSession` to the persistent transfer queue.
///
/// Callbacks can arrive on any queue; this object holds only a `Sendable`
/// actor reference, so it is safe to pass the instance to the queue.
final class WatchConnectivityService: NSObject, WCSessionDelegate, ChunkTransferTransport,
    @unchecked Sendable
{
    private let queue: WatchTransferQueue
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "transfer")

    init(queue: WatchTransferQueue) {
        self.queue = queue
        super.init()
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
        } else if let error {
            logger.error(
                "WCSession activation failed: \(String(describing: error), privacy: .public)"
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
        Task {
            await queue.handleTransferFinished(chunkID: chunkID, errorCode: code)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleAcknowledgement(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleAcknowledgement(message)
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
