import MapKit
import SwiftUI
import UIKit

/// A marker placed on a walk's route.
struct RouteMarker: Equatable {

    enum Kind: Equatable {
        case start
        case end
        /// A time label placed partway along the route.
        case time
    }

    let coordinate: Coordinate
    let title: String
    let kind: Kind
}

/// A small, static map showing one walk's trace.
///
/// The route is drawn as a dense line of dots rather than a solid stroke. At
/// street scale a solid line hides the road underneath it and makes doubling
/// back impossible to see, while dots keep both readable.
///
/// Only ever used one at a time. History rows draw a `RouteShape` instead,
/// because one `MKMapView` per row would be far too heavy for a list.
struct RouteMapView: UIViewRepresentable {

    let route: [Coordinate]
    var markers: [RouteMarker] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.mapType = .standard
        map.isAccessibilityElement = true
        map.accessibilityLabel = String(localized: "Map of the route walked")
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.apply(route: route, markers: markers, to: map)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
    }

    // MARK: - Annotation

    final class MarkerAnnotation: NSObject, MKAnnotation {

        let coordinate: CLLocationCoordinate2D
        let title: String?
        let kind: RouteMarker.Kind

        init(marker: RouteMarker) {
            self.coordinate = marker.coordinate.clCoordinate
            self.title = marker.title
            self.kind = marker.kind
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        /// Cheap identity for the current content, so a redraw does not rebuild
        /// the overlay and refit the camera on every SwiftUI update.
        private var appliedSignature: String?
        private var overlay: MKPolyline?

        func apply(route: [Coordinate], markers: [RouteMarker], to map: MKMapView) {
            let signature = "\(route.count)|\(markers.count)|\(route.first?.latitude ?? 0)"
            guard signature != appliedSignature else { return }
            appliedSignature = signature

            if let overlay {
                map.removeOverlay(overlay)
                self.overlay = nil
            }
            map.removeAnnotations(map.annotations)

            guard route.count > 1 else { return }

            var coordinates = route.map(\.clCoordinate)
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            overlay = line
            map.addOverlay(line, level: .aboveRoads)
            map.addAnnotations(markers.map { MarkerAnnotation(marker: $0) })

            map.setVisibleMapRect(
                line.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 44, left: 34, bottom: 34, right: 34),
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
            // A zero length dash with a round cap draws as a dot. The gap is
            // what sets how dense the line of dots is.
            renderer.lineDashPattern = [0.001, 8]
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let marker = annotation as? MarkerAnnotation else { return nil }

            let identifier = "walk.marker.\(marker.kind)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: marker, reuseIdentifier: identifier)

            view.annotation = marker
            view.canShowCallout = false
            view.image = Self.image(for: marker)
            view.centerOffset = marker.kind == .time ? CGPoint(x: 0, y: -14) : .zero
            view.isAccessibilityElement = true
            view.accessibilityLabel = marker.title
            return view
        }

        /// Markers are drawn once into an image rather than built from custom
        /// views: there are only a handful of them and an image needs no layout
        /// pass as the map moves.
        private static func image(for marker: MarkerAnnotation) -> UIImage {
            switch marker.kind {
            case .start:
                return circle(letter: String(localized: "S"), fill: WalkPalette.accentUIColor)
            case .end:
                return circle(letter: String(localized: "E"), fill: UIColor.label)
            case .time:
                return pill(text: marker.title ?? "")
            }
        }

        private static func circle(letter: String, fill: UIColor) -> UIImage {
            let size = CGSize(width: 28, height: 28)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
                UIColor.systemBackground.setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
                fill.setFill()
                UIBezierPath(ovalIn: rect).fill()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let text = letter as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: (size.width - textSize.width) / 2,
                        y: (size.height - textSize.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
        }

        private static func pill(text: String) -> UIImage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let label = text as NSString
            let textSize = label.size(withAttributes: attributes)
            let size = CGSize(width: ceil(textSize.width) + 18, height: ceil(textSize.height) + 10)

            return UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.black.withAlphaComponent(0.82).setFill()
                UIBezierPath(
                    roundedRect: CGRect(origin: .zero, size: size),
                    cornerRadius: size.height / 2
                ).fill()
                label.draw(
                    at: CGPoint(
                        x: (size.width - textSize.width) / 2,
                        y: (size.height - textSize.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
    }
}
