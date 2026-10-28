import AkaMemoCore
import MapKit
import SwiftUI

/// Inline MapKit preview of an imported track. Coordinates are read from the
/// local JSONL file; only Apple's map framework fetches map tiles.
struct LocationTrackMapPreview: View {
    let track: LocationTrackRecord

    @State private var points: [LocationPoint] = []
    @State private var didLoad = false

    private var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { point in
            guard point.latitude.isFinite,
                point.longitude.isFinite,
                (-90...90).contains(point.latitude),
                (-180...180).contains(point.longitude)
            else {
                return nil
            }
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bounds = LocationTrackBounds(points: points),
                !coordinates.isEmpty
            {
                Map(initialPosition: .region(region(for: bounds))) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, lineWidth: 3)
                    if let start = coordinates.first {
                        Marker("location.map.start", coordinate: start)
                            .tint(.green)
                    }
                    if let end = coordinates.last {
                        Marker("location.map.end", coordinate: end)
                            .tint(.red)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text("location.map.title"))
                .accessibilityValue(
                    Text("location.map.pointsValue \(coordinates.count)")
                )

                Text("location.map.footnote")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if didLoad {
                Text("location.map.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.vertical, 4)
        .task(id: track.trackID) {
            load()
        }
    }

    private func load() {
        defer { didLoad = true }
        do {
            let root = try PhonePaths.applicationSupport()
            let data = try Data(
                contentsOf: root.appending(path: track.relativePath)
            )
            points = LocationTrackCodec.decode(data).points
        } catch {
            points = []
        }
    }

    private func region(
        for bounds: LocationTrackBounds
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: bounds.centerLatitude,
                longitude: bounds.centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: bounds.latitudeSpan,
                longitudeDelta: bounds.longitudeSpan
            )
        )
    }
}
