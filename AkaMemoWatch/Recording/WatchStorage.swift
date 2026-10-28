import Foundation

enum WatchStorage {
    /// Free bytes on the volume that holds the app container.
    static func availableBytes() -> Int64? {
        guard let root = try? WatchPaths.applicationSupport() else {
            return nil
        }
        guard
            let values = try? root.resourceValues(
                forKeys: [.volumeAvailableCapacityKey]
            ),
            let bytes = values.volumeAvailableCapacity
        else {
            return nil
        }
        return Int64(bytes)
    }
}
