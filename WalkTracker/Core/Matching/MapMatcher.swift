import Foundation

/// Read-only spatial lookup over a city's street network.
public protocol SegmentIndex: AnyObject {
    func segments(near coordinate: Coordinate, radiusMetres: Double) -> [StreetSegment]
    func segment(id: Int64) -> StreetSegment?
}

/// A stretch of one block the matcher believes was walked.
public struct CoverageClaim: Equatable, Sendable {
    public let segmentID: Int64
    public let from: Double
    public let to: Double
    public let timestamp: Date

    public init(segmentID: Int64, from: Double, to: Double, timestamp: Date) {
        self.segmentID = segmentID
        self.from = min(from, to)
        self.to = max(from, to)
        self.timestamp = timestamp
    }

    public var isEmpty: Bool { to - from <= 0 }
}

/// Snaps a noisy GPS trace onto the street network.
///
/// Uses the standard hidden-Markov formulation of map matching: each fix has a
/// set of candidate blocks it might be on, scored by how far the fix sits from
/// the block (the emission term), and consecutive candidates are scored by how
/// well the distance along the network matches the distance the GPS moved (the
/// transition term). A Viterbi pass over a sliding window then picks the most
/// likely sequence rather than trusting any single fix.
///
/// This matters because a bare nearest-street rule fails in exactly the cities
/// this app targets: with 20-30 m of urban-canyon error and streets 60 m apart,
/// nearest-street flickers between parallel roads and paints streets the user
/// never set foot on.
///
/// The matcher is deliberately biased toward under-reporting. When it cannot
/// explain how the user got from one fix to the next, it emits nothing rather
/// than guessing, on the principle that a missing block is a much smaller harm
/// than a block wrongly marked walked.
public final class MapMatcher {

    public struct Configuration: Sendable {
        /// Candidate blocks are searched within this radius of each fix.
        public var searchRadiusMetres: Double = 60
        /// Fixes reporting worse accuracy than this are dropped outright.
        public var maxHorizontalAccuracy: Double = 30
        /// Floor on the emission sigma, so a fix claiming 1 m accuracy does not
        /// dominate the whole chain.
        public var minSigmaMetres: Double = 8
        /// Scale of the transition penalty, in metres.
        public var beta: Double = 12
        /// Number of fixes held before a decision is finalised. Larger means
        /// better decisions and more lag.
        public var windowSize: Int = 12
        /// A gap longer than this breaks the chain: we cannot assume the user
        /// walked the streets in between.
        public var maxGapSeconds: TimeInterval = 90
        /// Implied speeds above this are not walking, so the fix is dropped.
        /// 4.5 m/s is about 16 km/h, comfortably above a sprint but well below
        /// city traffic.
        public var maxSpeedMetresPerSecond: Double = 4.5
        /// Fixes closer together than this add noise without adding coverage.
        public var minPointSpacingMetres: Double = 2
        /// Log-probability penalty for stepping between blocks that do not
        /// share an intersection.
        public var disconnectedPenalty: Double = 4.0
        /// Log-probability penalty for stepping to an adjacent block. Turning
        /// is a rare event for a pedestrian, roughly once per block, so it has
        /// to carry real cost or the matcher wanders down every side street it
        /// passes.
        public var adjacentPenalty: Double = 2.0
        /// Weight of the directional term. Scaled by `(1 - cos 2d) / 2`, which
        /// is 0 when the course runs along the block and 1 when it is square
        /// across it, with period 180 so a two-way street scores the same
        /// whichever way it is walked.
        public var bearingWeight: Double = 5.0
        /// Multiplier on the two fixes' reported accuracies when deciding
        /// whether a jump was too far to be a walk. Without it, GPS noise alone
        /// looks like 20 m/s and every fix breaks the chain.
        public var noiseAllowanceFactor: Double = 3.0
        /// Pulls back single-fix excursions onto a neighbouring block.
        public var despeckle: Bool = true

        public init() {}
    }

    private struct Candidate {
        let segment: StreetSegment
        let projection: Polyline.Projection
    }

    private struct State {
        let candidate: Candidate
        let score: Double
        let backpointer: Int?
    }

    private struct Step {
        let point: TrackPoint
        let states: [State]
    }

    private let index: SegmentIndex
    private let configuration: Configuration

    private struct Decision {
        let segment: StreetSegment
        let fraction: Double
        let timestamp: Date
        let coordinate: Coordinate
    }

    private var window: [Step] = []
    private var lastAcceptedPoint: TrackPoint?
    /// Settled decisions waiting to be despeckled and turned into claims. Held
    /// briefly so each one can be judged against the decision on either side.
    private var decisions: [Decision] = []

    public init(index: SegmentIndex, configuration: Configuration = Configuration()) {
        self.index = index
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Feeds one fix in and returns any coverage it lets us finalise.
    public func ingest(_ point: TrackPoint) -> [CoverageClaim] {
        guard isAcceptable(point) else { return [] }

        // A long gap, or a jump too fast to be walking, means we cannot claim
        // whatever lies between. Close out what we have and start fresh.
        if let previous = lastAcceptedPoint {
            let elapsed = point.timestamp.timeIntervalSince(previous.timestamp)
            let moved = GeoMath.haversine(previous.coordinate, point.coordinate)

            if elapsed <= 0 { return [] }
            if moved < configuration.minPointSpacingMetres && elapsed < 30 { return [] }

            // Compare against a budget that accounts for the noise in both
            // fixes, not against raw differenced positions.
            let noiseAllowance = configuration.noiseAllowanceFactor
                * (previous.horizontalAccuracy + point.horizontalAccuracy)
            let plausible = configuration.maxSpeedMetresPerSecond * elapsed + noiseAllowance

            if elapsed > configuration.maxGapSeconds || moved > plausible {
                let flushed = flush()
                lastAcceptedPoint = point
                seedWindow(with: point)
                return flushed
            }
        }

        let candidates = candidates(for: point)
        guard !candidates.isEmpty else {
            // Off the network entirely: inside a park, a building, or a pack
            // gap. Break the chain rather than snapping to a distant street.
            let flushed = flush()
            lastAcceptedPoint = point
            return flushed
        }

        advance(with: point, candidates: candidates)
        lastAcceptedPoint = point

        return finalizeIfNeeded()
    }

    /// Finalises everything still in the window. Call when tracking stops.
    public func flush() -> [CoverageClaim] {
        var claims: [CoverageClaim] = []
        while !window.isEmpty {
            if let emitted = finalizeOldest() {
                claims.append(contentsOf: emitted)
            }
        }
        claims.append(contentsOf: drain(final: true))
        decisions.removeAll()
        lastAcceptedPoint = nil
        return claims.filter { !$0.isEmpty }
    }

    public func reset() {
        window.removeAll()
        decisions.removeAll()
        lastAcceptedPoint = nil
    }

    // MARK: - Gating

    private func isAcceptable(_ point: TrackPoint) -> Bool {
        guard point.coordinate.isValid else { return false }
        guard point.horizontalAccuracy >= 0 else { return false }
        guard point.horizontalAccuracy <= configuration.maxHorizontalAccuracy else { return false }
        // A reported speed above the walking ceiling means a vehicle, even if
        // the positions themselves look plausible.
        if point.speed >= 0 && point.speed > configuration.maxSpeedMetresPerSecond { return false }
        return true
    }

    // MARK: - Viterbi

    private func candidates(for point: TrackPoint) -> [Candidate] {
        let nearby = index.segments(
            near: point.coordinate,
            radiusMetres: configuration.searchRadiusMetres
        )
        return nearby.compactMap { segment in
            let projection = segment.geometry.project(point.coordinate)
            guard projection.distance <= configuration.searchRadiusMetres else { return nil }
            return Candidate(segment: segment, projection: projection)
        }
    }

    private func seedWindow(with point: TrackPoint) {
        window.removeAll()
        decisions.removeAll()
        let candidates = candidates(for: point)
        guard !candidates.isEmpty else { return }
        advance(with: point, candidates: candidates)
    }

    private func advance(with point: TrackPoint, candidates: [Candidate]) {
        let sigma = max(configuration.minSigmaMetres, point.horizontalAccuracy)

        guard let previousStep = window.last else {
            let states = candidates.map { candidate in
                State(
                    candidate: candidate,
                    score: emissionLogProbability(candidate, sigma: sigma, point: point),
                    backpointer: nil
                )
            }
            window.append(Step(point: point, states: states))
            return
        }

        let gpsDelta = GeoMath.haversine(previousStep.point.coordinate, point.coordinate)

        var states: [State] = []
        states.reserveCapacity(candidates.count)

        for candidate in candidates {
            let emission = emissionLogProbability(candidate, sigma: sigma, point: point)

            var bestScore = -Double.greatestFiniteMagnitude
            var bestBack: Int?

            for (i, previousState) in previousStep.states.enumerated() {
                let transition = transitionLogProbability(
                    from: previousState.candidate,
                    to: candidate,
                    gpsDelta: gpsDelta
                )
                let total = previousState.score + transition
                if total > bestScore {
                    bestScore = total
                    bestBack = i
                }
            }

            guard bestBack != nil else { continue }
            states.append(State(candidate: candidate, score: bestScore + emission, backpointer: bestBack))
        }

        guard !states.isEmpty else { return }

        // Keep scores bounded so a long walk cannot drift toward -infinity.
        let best = states.map(\.score).max() ?? 0
        let normalized = states.map {
            State(candidate: $0.candidate, score: $0.score - best, backpointer: $0.backpointer)
        }

        window.append(Step(point: point, states: normalized))
    }

    private func emissionLogProbability(_ candidate: Candidate, sigma: Double, point: TrackPoint) -> Double {
        let z = candidate.projection.distance / sigma
        var score = -0.5 * z * z

        // Course is only meaningful when moving; CoreLocation reports -1 when
        // it has none, and a stationary fix has an arbitrary heading.
        if point.course >= 0, point.speed > 0.5 {
            let delta = GeoMath.bearingDelta(point.course, candidate.projection.bearing) * .pi / 180
            score -= configuration.bearingWeight * (1 - cos(2 * delta)) / 2
        }
        return score
    }

    private func transitionLogProbability(
        from previous: Candidate,
        to current: Candidate,
        gpsDelta: Double
    ) -> Double {
        let routeDelta: Double
        var penalty: Double

        if previous.segment.id == current.segment.id {
            routeDelta = abs(current.projection.offset - previous.projection.offset)
            penalty = 0
        } else if let node = previous.segment.sharedNode(with: current.segment) {
            let outgoing = distanceToNode(node, on: previous.segment, from: previous.projection)
            let incoming = distanceToNode(node, on: current.segment, from: current.projection)
            routeDelta = outgoing + incoming
            penalty = configuration.adjacentPenalty
        } else {
            // Not directly connected. The straight line understates the real
            // walking distance, which is exactly why this is penalised.
            let a = previous.segment.geometry.coordinate(atFraction: previous.projection.fraction)
            let b = current.segment.geometry.coordinate(atFraction: current.projection.fraction)
            routeDelta = GeoMath.haversine(a, b)
            penalty = configuration.disconnectedPenalty
        }

        return -abs(gpsDelta - routeDelta) / configuration.beta - penalty
    }

    /// Distance along `segment` from the projected point to the given endpoint.
    private func distanceToNode(_ node: Int64, on segment: StreetSegment, from projection: Polyline.Projection) -> Double {
        if node == segment.startNodeID {
            return projection.offset
        }
        return max(0, segment.geometry.length - projection.offset)
    }

    // MARK: - Finalisation

    private func finalizeIfNeeded() -> [CoverageClaim] {
        guard window.count > configuration.windowSize else { return [] }
        return finalizeOldest() ?? []
    }

    /// Commits the oldest fix in the window using the best path currently known.
    private func finalizeOldest() -> [CoverageClaim]? {
        guard !window.isEmpty else { return nil }

        guard let decided = backtraceOldest() else {
            window.removeFirst()
            return nil
        }
        let step = window.removeFirst()

        decisions.append(Decision(
            segment: decided.segment,
            fraction: decided.projection.fraction,
            timestamp: step.point.timestamp,
            coordinate: step.point.coordinate
        ))
        return drain(final: false)
    }

    /// Pulls back a one-fix hop onto a different block when the decisions on
    /// either side agree on the original. A pedestrian does not dart sixty
    /// metres down a side street and back in a few seconds; GPS does.
    private func despeckle() {
        guard configuration.despeckle else { return }
        let middle = decisions.count - 2
        guard middle >= 1 else { return }

        let before = decisions[middle - 1]
        let suspect = decisions[middle]
        let after = decisions[middle + 1]

        guard before.segment.id == after.segment.id,
              suspect.segment.id != before.segment.id else { return }

        let projection = before.segment.geometry.project(suspect.coordinate)
        decisions[middle] = Decision(
            segment: before.segment,
            fraction: projection.fraction,
            timestamp: suspect.timestamp,
            coordinate: suspect.coordinate
        )
    }

    /// Turns settled decisions into claims, keeping enough in reserve that
    /// every decision gets despeckled before it is used.
    private func drain(final: Bool) -> [CoverageClaim] {
        var claims: [CoverageClaim] = []
        despeckle()

        let keep = final ? 1 : 3
        while decisions.count > keep {
            let from = decisions[0]
            let to = decisions[1]
            claims.append(contentsOf: bridge(
                fromSegment: from.segment.id,
                fromFraction: from.fraction,
                toSegment: to.segment,
                toFraction: to.fraction,
                timestamp: to.timestamp
            ))
            decisions.removeFirst()
            if !final { break }
        }
        return claims
    }

    /// Walks the Viterbi backpointers from the best state in the newest step
    /// back to the oldest, and returns the oldest step's chosen candidate.
    private func backtraceOldest() -> Candidate? {
        guard let lastStep = window.last, !lastStep.states.isEmpty else { return nil }

        var cursor = lastStep.states.enumerated().max(by: { $0.element.score < $1.element.score })?.offset
        guard cursor != nil else { return nil }

        for i in stride(from: window.count - 1, through: 1, by: -1) {
            guard let current = cursor, current < window[i].states.count else { return nil }
            cursor = window[i].states[current].backpointer
            guard cursor != nil else { return nil }
        }

        guard let first = cursor, first < window[0].states.count else { return nil }
        return window[0].states[first].candidate
    }

    /// Produces the coverage implied by moving between two finalised fixes.
    private func bridge(
        fromSegment: Int64,
        fromFraction: Double,
        toSegment: StreetSegment,
        toFraction: Double,
        timestamp: Date
    ) -> [CoverageClaim] {
        if fromSegment == toSegment.id {
            return [CoverageClaim(segmentID: fromSegment, from: fromFraction, to: toFraction, timestamp: timestamp)]
        }

        guard let previousSegment = index.segment(id: fromSegment),
              let node = previousSegment.sharedNode(with: toSegment) else {
            // No known path between the two blocks: claim nothing rather than
            // inventing a route.
            return []
        }

        var claims: [CoverageClaim] = []

        // Finish the block we were on, out to the intersection we left by.
        let exitFraction: Double = node == previousSegment.endNodeID ? 1.0 : 0.0
        claims.append(CoverageClaim(segmentID: fromSegment, from: fromFraction, to: exitFraction, timestamp: timestamp))

        // Then cover the new block from that same intersection inward.
        let entryFraction: Double = node == toSegment.startNodeID ? 0.0 : 1.0
        claims.append(CoverageClaim(segmentID: toSegment.id, from: entryFraction, to: toFraction, timestamp: timestamp))

        return claims.filter { !$0.isEmpty }
    }
}
