import AkaMemoCore
import CoreLocation
import Foundation
import OSLog
import Observation

struct LocationTrackUpload: Sendable {
    let fileURL: URL
    let envelope: TrackTransferEnvelope
}

/// Records a low-frequency location track for one recording session.
///
/// The manager receives continuous updates while recording, but only one
/// point per five minutes is written. Permission denial never affects audio.
@MainActor
@Observable
final class LocationRecorder: NSObject, CLLocationManagerDelegate {
    enum Status: String, Sendable {
        case idle
        case requesting
        case recording
        case paused
        case unavailable
        case disabled
        case completed
        case failed
    }

    static let enabledKey = "location.enabled"

    private(set) var status: Status = .idle
    private(set) var isEnabled: Bool
    private(set) var recordedPointCount = 0
    private(set) var lowConfidencePointCount = 0

    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "location"
    )
    private var sessionID: UUID?
    private var sessionStartedAtMs: Int64?
    private var trackID = UUID()
    private var writer: LocationFileWriter?
    private var lastRecordedAtMs: Int64?
    private var firstRecordedAtMs: Int64?
    private var isPaused = false
    private var isSessionActive = false

    override init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        self.isEnabled =
            defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
    }

    var isRecording: Bool {
        isSessionActive
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            manager.stopUpdatingLocation()
            if isSessionActive {
                status = .disabled
            }
        } else if isSessionActive, !isPaused {
            beginUpdates()
        }
    }

    func updateLowPowerMode(_ lowPower: Bool) {
        manager.desiredAccuracy =
            lowPower ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
    }

    func start(sessionID: UUID, sessionStartedAt: Date) {
        guard isEnabled else {
            status = .disabled
            return
        }
        self.sessionID = sessionID
        self.sessionStartedAtMs = TimeMath.epochMs(sessionStartedAt)
        self.trackID = UUID()
        self.lastRecordedAtMs = nil
        self.firstRecordedAtMs = nil
        self.recordedPointCount = 0
        self.lowConfidencePointCount = 0
        self.isPaused = false
        self.isSessionActive = true
        do {
            writer = try LocationFileWriter(
                fileURL: WatchPaths.locationFileURL(sessionID: sessionID)
            )
        } catch {
            status = .failed
            logger.error("could not create location file")
            return
        }
        guard ensureAuthorization() else {
            return
        }
        beginUpdates()
    }

    func pause() {
        guard isSessionActive else {
            return
        }
        isPaused = true
        manager.stopUpdatingLocation()
        if isEnabled {
            status = .paused
        }
    }

    func resume() {
        guard isSessionActive, isEnabled else {
            return
        }
        isPaused = false
        beginUpdates()
    }

    /// Stops without producing an upload; used when the session is deleted.
    func cancelSession() async {
        guard isSessionActive else {
            return
        }
        isSessionActive = false
        manager.stopUpdatingLocation()
        await writer?.cancel()
        writer = nil
        status = .completed
    }

    func stopSession(endedAt: Date = Date()) async -> LocationTrackUpload? {
        guard isSessionActive else {
            return nil
        }
        isSessionActive = false
        manager.stopUpdatingLocation()
        guard let writer, let sessionID, let sessionStartedAtMs else {
            return nil
        }
        self.writer = nil
        do {
            let result = try await writer.finalize()
            guard result.pointCount > 0 else {
                status = .unavailable
                return nil
            }
            let data = try Data(contentsOf: result.url)
            let checksum = AtomicFileWriter.sha256Hex(data)
            let endedAtMs = lastRecordedAtMs ?? TimeMath.epochMs(endedAt)
            let envelope = TrackTransferEnvelope(
                trackID: trackID,
                sessionID: sessionID,
                sessionStartedAtMs: sessionStartedAtMs,
                startedAtMs: firstRecordedAtMs ?? sessionStartedAtMs,
                endedAtMs: max(endedAtMs, firstRecordedAtMs ?? endedAtMs),
                pointCount: result.pointCount,
                checksumSHA256: checksum,
                relativePath: "location/\(sessionID.uuidString).jsonl"
            )
            status = .completed
            return LocationTrackUpload(fileURL: result.url, envelope: envelope)
        } catch {
            status = .failed
            logger.error("could not finalize location file")
            return nil
        }
    }

    private func beginUpdates() {
        status = .recording
        manager.startUpdatingLocation()
    }

    private func ensureAuthorization() -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined:
            status = .requesting
            manager.requestWhenInUseAuthorization()
            return false
        default:
            status = .unavailable
            return false
        }
    }

    private func handleAuthorizationChange() {
        guard isSessionActive, isEnabled else {
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !isPaused {
                beginUpdates()
            }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            status = .unavailable
        default:
            break
        }
    }

    private func handle(_ location: CLLocation) async {
        guard isSessionActive, isEnabled, !isPaused, let writer else {
            return
        }
        let point = makePoint(from: location)
        guard
            LocationSamplingPolicy.standard.shouldRecord(
                point,
                lastRecordedAtMs: lastRecordedAtMs
            )
        else {
            return
        }
        do {
            try await writer.append(point)
        } catch {
            status = .failed
            logger.error("could not write location point")
            return
        }
        lastRecordedAtMs = point.timestampMs
        firstRecordedAtMs = firstRecordedAtMs ?? point.timestampMs
        recordedPointCount += 1
        if LocationSamplingPolicy.standard.isLowConfidence(point) {
            lowConfidencePointCount += 1
        }
    }

    private func makePoint(from location: CLLocation) -> LocationPoint {
        LocationPoint(
            timestampMs: TimeMath.epochMs(location.timestamp),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0
                ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy >= 0
                ? location.verticalAccuracy : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil
        )
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        Task { @MainActor in
            handleAuthorizationChange()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else {
            return
        }
        Task { @MainActor in
            await handle(location)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            if let clError = error as? CLError, clError.code == .denied {
                self.manager.stopUpdatingLocation()
                self.status = .unavailable
            } else if self.isSessionActive, self.isEnabled {
                self.status = .recording
            }
        }
    }
}

/// Appends JSONL lines to `<sessionID>.jsonl.part` and renames on finalize.
actor LocationFileWriter {
    struct Result: Sendable {
        let url: URL
        let pointCount: Int
    }

    enum WriteError: Error {
        case unavailable
    }

    private let partURL: URL
    private let finalURL: URL
    private var handle: FileHandle?
    private var pointCount = 0

    init(fileURL: URL) throws {
        self.finalURL = fileURL
        self.partURL = fileURL.appendingPathExtension("part")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: partURL)
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: partURL)
    }

    func append(_ point: LocationPoint) throws {
        guard let handle else {
            throw WriteError.unavailable
        }
        let data = try LocationTrackCodec.encodeLine(point)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        pointCount += 1
        if pointCount % 10 == 0 {
            try handle.synchronize()
        }
    }

    func cancel() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partURL)
    }

    func finalize() throws -> Result {
        guard let handle else {
            throw WriteError.unavailable
        }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        guard pointCount > 0 else {
            try? FileManager.default.removeItem(at: partURL)
            return Result(url: finalURL, pointCount: 0)
        }
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        #if os(watchOS)
            try? FileManager.default.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: finalURL.path
            )
        #endif
        return Result(url: finalURL, pointCount: pointCount)
    }
}
