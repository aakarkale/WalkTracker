import MapKit
import SwiftUI

// MARK: - Overlay bundle

/// The street geometry currently on the map, as at most two overlay objects.
///
/// This is the single most important performance decision in the app. A city
/// view can hold tens of thousands of blocks, and adding one `MKPolyline`
/// overlay per block means one `MKOverlayRenderer` per block, each with its own
/// draw pass and its own hit testing: MapKit stutters badly long before twenty
/// thousand of them. `MKMultiPolyline` collapses every line of one colour into
/// a single overlay drawn by a single renderer, so the renderer count stays at
/// two however dense the streets get.
///
/// Marked `@unchecked Sendable` because the bundle is built once on a
/// background thread and then only read: nothing mutates it after `init`.
final class StreetOverlayBundle: @unchecked Sendable {

    let unwalked: MKMultiPolyline?
    let walked: MKMultiPolyline?
    /// The same lines as `walked`, drawn underneath, wider and fainter.
    ///
    /// A separate object because MapKit will not accept one overlay twice, and
    /// two renderers over the same geometry is how a line is made to look lit
    /// rather than merely coloured.
    let walkedGlow: MKMultiPolyline?
    /// Identifies this set of overlays, so the map view can tell whether the
    /// overlays it is holding are still the current ones.
    let generation: Int
    let segmentCount: Int

    init(
        unwalked: MKMultiPolyline?,
        walked: MKMultiPolyline?,
        walkedGlow: MKMultiPolyline?,
        generation: Int,
        segmentCount: Int
    ) {
        self.unwalked = unwalked
        self.walked = walked
        self.walkedGlow = walkedGlow
        self.generation = generation
        self.segmentCount = segmentCount
    }
}

// MARK: - Camera

/// A one-shot request to move the camera.
///
/// Compared by identity rather than by position: re-sending the same region
/// while the user is panning would yank the map out from under them, so the
/// map applies each request exactly once.
struct MapFocusRequest: Equatable {

    let id = UUID()
    let center: CLLocationCoordinate2D
    let spanMetres: CLLocationDistance

    static func == (lhs: MapFocusRequest, rhs: MapFocusRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// What the map can currently see, in terms the rest of the app understands.
struct VisibleArea: Equatable {
    let box: BoundingBox
    let widthMetres: Double
}

// MARK: - Map view

/// An `MKMapView` wrapped for SwiftUI.
///
/// SwiftUI's own `Map` cannot do this job: it offers no renderer-level control,
/// so it cannot batch thousands of lines into one overlay, cannot set a stroke
/// width per layer, and gives no reliable hook for "the user stopped panning,
/// load what is now visible". All three are the whole design here.
struct StreetMapView: UIViewRepresentable {

    let overlays: StreetOverlayBundle?
    let showsUserLocation: Bool
    var appearance: MapAppearance = .system
    let focus: MapFocusRequest?
    /// Incremented by the caller to ask the map to recentre on the user once.
    let followRequest: Int
    let onVisibleAreaChange: (VisibleArea) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibleAreaChange: onVisibleAreaChange)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = showsUserLocation
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        // The standard base map, left exactly as Apple draws it in whichever
        // theme is in force. The coverage is what this screen is about and is
        // drawn over the top; restyling the map underneath would only make it
        // harder to read.
        map.mapType = .standard
        apply(appearance: appearance, to: map)
        return map
    }

    /// Overriding the interface style on the map view alone themes the base
    /// map without dragging the rest of the app dark with it, and the dynamic
    /// overlay colours resolve against the override rather than the system.
    private func apply(appearance: MapAppearance, to map: MKMapView) {
        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        guard map.overrideUserInterfaceStyle != style else { return }
        map.overrideUserInterfaceStyle = style
        // The overlay renderers cached their colours against the old style.
        for overlay in map.overlays {
            map.renderer(for: overlay)?.setNeedsDisplay()
        }
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onVisibleAreaChange = onVisibleAreaChange
        apply(appearance: appearance, to: map)
        if map.showsUserLocation != showsUserLocation {
            map.showsUserLocation = showsUserLocation
        }
        context.coordinator.apply(bundle: overlays, to: map)
        context.coordinator.apply(focus: focus, to: map)
        context.coordinator.apply(followRequest: followRequest, to: map)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
        map.removeOverlays(map.overlays)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        var onVisibleAreaChange: (VisibleArea) -> Void

        private var appliedGeneration: Int?
        private var unwalkedOverlay: MKMultiPolyline?
        private var walkedOverlay: MKMultiPolyline?
        private var walkedGlowOverlay: MKMultiPolyline?
        private var appliedFocusID: UUID?
        private var appliedFollowRequest = 0

        init(onVisibleAreaChange: @escaping (VisibleArea) -> Void) {
            self.onVisibleAreaChange = onVisibleAreaChange
        }

        // MARK: Applying state

        func apply(bundle: StreetOverlayBundle?, to map: MKMapView) {
            guard bundle?.generation != appliedGeneration else { return }
            appliedGeneration = bundle?.generation

            let previous = [unwalkedOverlay, walkedGlowOverlay, walkedOverlay].compactMap { $0 }
            unwalkedOverlay = bundle?.unwalked
            walkedGlowOverlay = bundle?.walkedGlow
            walkedOverlay = bundle?.walked

            // The new overlays go on before the old ones come off, so the
            // streets do not blink out for a frame while the user is panning.
            // Both sit above roads but below labels, so street names stay
            // readable through the drawing.
            // Order matters: unwalked, then the halo, then the bright core on
            // top of its own glow.
            if let unwalked = bundle?.unwalked {
                map.addOverlay(unwalked, level: .aboveRoads)
            }
            if let glow = bundle?.walkedGlow {
                map.addOverlay(glow, level: .aboveRoads)
            }
            if let walked = bundle?.walked {
                map.addOverlay(walked, level: .aboveRoads)
            }
            if !previous.isEmpty {
                map.removeOverlays(previous)
            }
        }

        func apply(focus: MapFocusRequest?, to map: MKMapView) {
            guard let focus, focus.id != appliedFocusID else { return }
            appliedFocusID = focus.id

            let region = MKCoordinateRegion(
                center: focus.center,
                latitudinalMeters: focus.spanMetres,
                longitudinalMeters: focus.spanMetres
            )
            map.setRegion(map.regionThatFits(region), animated: true)
        }

        func apply(followRequest: Int, to map: MKMapView) {
            guard followRequest != appliedFollowRequest else { return }
            appliedFollowRequest = followRequest
            map.setUserTrackingMode(.follow, animated: true)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let multi = overlay as? MKMultiPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            // Identity rather than a subclass: there are exactly two overlays
            // and the coordinator already holds both of them.
            // Walked streets are both the accent colour and the heavier
            // stroke, so they read first at every zoom level.
            if multi === walkedOverlay {
                renderer.strokeColor = WalkPalette.walkedCoreUIColor
                renderer.lineWidth = 4
            } else if multi === walkedGlowOverlay {
                // Roughly triple the core width. Wide enough to read as a
                // halo, narrow enough that neighbouring streets do not bleed
                // into one another at city zoom.
                renderer.strokeColor = WalkPalette.walkedGlowUIColor
                renderer.lineWidth = 13
            } else {
                renderer.strokeColor = WalkPalette.unwalkedUIColor
                renderer.lineWidth = 2.5
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Fires once the map has settled, which is the right moment to ask
            // for the streets now on screen. The debouncing itself lives in the
            // loader, because a programmatic recentre can fire this repeatedly.
            onVisibleAreaChange(Self.visibleArea(of: mapView))
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            // Covers the first layout, where a region change may never fire.
            onVisibleAreaChange(Self.visibleArea(of: mapView))
        }

        private static func visibleArea(of map: MKMapView) -> VisibleArea {
            let region = map.region
            let halfLatitude = max(0, region.span.latitudeDelta / 2)
            let halfLongitude = max(0, region.span.longitudeDelta / 2)

            let box = BoundingBox(
                minLatitude: max(-90, region.center.latitude - halfLatitude),
                minLongitude: max(-180, region.center.longitude - halfLongitude),
                maxLatitude: min(90, region.center.latitude + halfLatitude),
                maxLongitude: min(180, region.center.longitude + halfLongitude)
            )

            let metresPerPoint = MKMetersPerMapPointAtLatitude(region.center.latitude)
            return VisibleArea(
                box: box,
                widthMetres: map.visibleMapRect.size.width * metresPerPoint
            )
        }
    }
}
