import SwiftUI

/// Turns geographic traces into unit-space points a `Shape` can draw.
///
/// Normalising is done once, off the main thread, and the result cached by the
/// caller. A history list that recomputed this while scrolling would drop
/// frames on the exact screen where smoothness is most obvious.
enum RouteGeometry {

    /// Projects and scales one trace into the unit square, keeping its aspect
    /// ratio and centring it, with the y axis flipped so north is up.
    ///
    /// - Parameter limit: the most points to keep. A walk can hold thousands of
    ///   fixes and a thumbnail is a few dozen pixels wide, so the trace is
    ///   decimated rather than drawn in full.
    static func normalise(_ coordinates: [Coordinate], limit: Int = 90) -> [CGPoint] {
        normalise(runs: [coordinates], limitPerRun: limit).first ?? []
    }

    /// Normalises several traces into one shared unit space, so they stay in
    /// the right position relative to each other.
    static func normalise(runs: [[Coordinate]], limitPerRun: Int = 90) -> [[CGPoint]] {
        let sampled = runs.map { decimate($0.filter(\.isValid), limit: limitPerRun) }.filter { $0.count > 1 }
        guard !sampled.isEmpty else { return [] }

        let all = sampled.flatMap { $0 }
        let meanLatitude = all.reduce(0) { $0 + $1.latitude } / Double(all.count)
        // Equirectangular is plenty for a thumbnail: over a few kilometres the
        // error is far below one pixel, and it costs one cosine.
        let longitudeScale = cos(meanLatitude * .pi / 180)

        let projected = sampled.map { run in
            run.map { CGPoint(x: $0.longitude * longitudeScale, y: $0.latitude) }
        }
        let flat = projected.flatMap { $0 }

        guard let minX = flat.map(\.x).min(), let maxX = flat.map(\.x).max(),
              let minY = flat.map(\.y).min(), let maxY = flat.map(\.y).max() else { return [] }

        let width = maxX - minX
        let height = maxY - minY
        let span = max(width, height)
        guard span > 0 else { return [] }

        // Centres the smaller axis so the drawing is not stuck to one edge.
        let insetX = (span - width) / 2
        let insetY = (span - height) / 2

        return projected.map { run in
            run.map { point in
                CGPoint(
                    x: (point.x - minX + insetX) / span,
                    // Screen y grows downward, latitude grows upward.
                    y: 1 - (point.y - minY + insetY) / span
                )
            }
        }
    }

    private static func decimate(_ coordinates: [Coordinate], limit: Int) -> [Coordinate] {
        guard coordinates.count > limit, limit > 1 else { return coordinates }
        let step = max(1, coordinates.count / limit)
        var result: [Coordinate] = []
        result.reserveCapacity(limit + 1)
        var index = 0
        while index < coordinates.count {
            result.append(coordinates[index])
            index += step
        }
        if let last = coordinates.last, result.last != last {
            result.append(last)
        }
        return result
    }
}

/// One trace, already normalised into unit space.
struct RouteShape: Shape {

    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        MultiRouteShape(runs: [points]).path(in: rect)
    }
}

/// Several traces sharing one unit space.
struct MultiRouteShape: Shape {

    let runs: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in runs where run.count > 1 {
            var isFirst = true
            for point in run {
                let placed = CGPoint(
                    x: rect.minX + point.x * rect.width,
                    y: rect.minY + point.y * rect.height
                )
                if isFirst {
                    path.move(to: placed)
                    isFirst = false
                } else {
                    path.addLine(to: placed)
                }
            }
        }
        return path
    }
}

/// The little route drawing in a history row.
struct RouteThumbnail: View {

    let points: [CGPoint]
    var lineWidth: CGFloat = 2
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(WalkPalette.accent.opacity(0.08))
            .overlay {
                if points.count > 1 {
                    RouteShape(points: points)
                        .stroke(
                            WalkPalette.accent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                        .padding(6)
                } else {
                    Image(systemName: "figure.walk")
                        .font(.caption)
                        .foregroundStyle(WalkPalette.accent.opacity(0.5))
                }
            }
            .accessibilityHidden(true)
    }
}
