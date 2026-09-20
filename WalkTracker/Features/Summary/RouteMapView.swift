import MapKit
import SwiftUI

/// A small, static map showing one walk's trace.
///
/// Only ever used once at a time, on the summary screen. History rows draw a
/// `RouteShape` instead, because one `MKMapView` per row would be far too
/// heavy for a scrolling list.
struct RouteMapView: UIViewRepresentable {

    let route: [Coordinate]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.mapType = .standard
        map.isAccessibilityElement = true
        map.accessibilityLabel = String(localized: "Map of the route you just walked")
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.apply(route: route, to: map)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
        map.removeOverlays(map.overlays)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {

        private var appliedPointCount = -1
        private var overlay: MKPolyline?

        func apply(route: [Coordinate], to map: MKMapView) {
            guard route.count != appliedPointCount else { return }
            appliedPointCount = route.count

            if let overlay {
                map.removeOverlay(overlay)
                self.overlay = nil
            }
            guard route.count > 1 else { return }

            var coordinates = route.map(\.clCoordinate)
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            overlay = line
            map.addOverlay(line, level: .aboveRoads)
            map.setVisibleMapRect(
                line.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26),
                animated: false
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = WalkPalette.accentUIColor
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}
