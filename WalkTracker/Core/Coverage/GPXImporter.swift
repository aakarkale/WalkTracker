import Foundation

/// Reads walks out of a GPX file.
///
/// This is the answer to the cold start problem. Somebody who has lived in a
/// city for ten years opens this app and sees 0%, which is both discouraging
/// and false. If they have been recording walks in anything else, GPX is what
/// it exports, so their real coverage can be filled in on day one.
///
/// The file is untrusted input: it arrives from a share sheet or a file
/// picker and is parsed by an XML reader. External entity resolution is off,
/// sizes are capped, and anything unparseable is skipped and counted rather
/// than aborting an import that is otherwise fine.
public final class GPXImporter: NSObject {

    public struct Track: Equatable, Sendable {
        public let name: String?
        public let points: [TrackPoint]
    }

    public enum ImportError: Error, LocalizedError {
        case tooLarge(limit: Int)
        case notGPX
        case noTracks

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                return "That file is larger than the \(limit / 1_048_576) MB import limit."
            case .notGPX:
                return "That file could not be read as GPX."
            case .noTracks:
                return "That file contains no tracks with timestamped positions."
            }
        }
    }

    /// Ceiling on the file. A year of dense tracking is a few tens of
    /// megabytes; anything past this is not a walking history.
    public static let maximumBytes = 64 * 1024 * 1024

    /// A gap this long inside one track segment starts a new walk. GPX files
    /// from some tools concatenate a whole year into a single segment, and
    /// treating that as one walk would invent a route across every gap.
    public static let sessionGap: TimeInterval = 30 * 60

    // Parser state.
    private var tracks: [Track] = []
    private var currentName: String?
    private var currentPoints: [TrackPoint] = []
    private var pendingLatitude: Double?
    private var pendingLongitude: Double?
    private var pendingElevation: Double?
    private var pendingTime: Date?
    private var textBuffer = ""
    private var skippedPoints = 0

    private static let timestampFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [plain, withFraction]
    }()

    public override init() {
        super.init()
    }

    /// Parses `data` into tracks, splitting on long time gaps.
    public func tracks(from data: Data) throws -> [Track] {
        guard data.count <= Self.maximumBytes else {
            throw ImportError.tooLarge(limit: Self.maximumBytes)
        }

        tracks = []
        currentName = nil
        currentPoints = []
        skippedPoints = 0

        let parser = XMLParser(data: data)
        parser.delegate = self
        // External entities are how an XML parser gets talked into reading
        // files off the device or making network requests. Nothing in GPX
        // needs them.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false

        guard parser.parse() else { throw ImportError.notGPX }
        flushTrack()

        let split = tracks.flatMap(splitOnGaps)
        guard !split.isEmpty else { throw ImportError.noTracks }
        return split
    }

    /// Number of points dropped for missing or invalid data in the last parse.
    public private(set) var lastSkippedPointCount: Int = 0

    private func splitOnGaps(_ track: Track) -> [Track] {
        guard track.points.count > 1 else {
            return track.points.isEmpty ? [] : [track]
        }
        var result: [Track] = []
        var run: [TrackPoint] = [track.points[0]]

        for point in track.points.dropFirst() {
            let gap = point.timestamp.timeIntervalSince(run[run.count - 1].timestamp)
            if gap > Self.sessionGap || gap < 0 {
                if run.count > 1 { result.append(Track(name: track.name, points: run)) }
                run = [point]
            } else {
                run.append(point)
            }
        }
        if run.count > 1 { result.append(Track(name: track.name, points: run)) }
        return result
    }

    private func flushTrack() {
        defer {
            currentPoints = []
            currentName = nil
        }
        guard currentPoints.count > 1 else { return }
        tracks.append(Track(name: currentName, points: currentPoints.sorted { $0.timestamp < $1.timestamp }))
    }
}

// MARK: - XMLParserDelegate

extension GPXImporter: XMLParserDelegate {

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        textBuffer = ""
        switch elementName {
        case "trk":
            flushTrack()
        case "trkpt", "wpt", "rtept":
            pendingLatitude = attributes["lat"].flatMap(Double.init)
            pendingLongitude = attributes["lon"].flatMap(Double.init)
            pendingElevation = nil
            pendingTime = nil
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Bounded so a pathological file cannot grow this without limit. No
        // legitimate GPX leaf element is anywhere near this long.
        guard textBuffer.count < 4_096 else { return }
        textBuffer += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""

        switch elementName {
        case "name" where currentName == nil && !text.isEmpty:
            currentName = text
        case "ele":
            pendingElevation = Double(text)
        case "time":
            pendingTime = Self.parseTimestamp(text)
        case "trkpt", "wpt", "rtept":
            appendPendingPoint()
        case "trk":
            flushTrack()
        default:
            break
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        lastSkippedPointCount = skippedPoints
    }

    private func appendPendingPoint() {
        defer {
            pendingLatitude = nil
            pendingLongitude = nil
            pendingElevation = nil
            pendingTime = nil
        }

        guard let latitude = pendingLatitude,
              let longitude = pendingLongitude,
              let timestamp = pendingTime else {
            // A point with no timestamp cannot be matched: the matcher reasons
            // about how far someone moved between fixes and in how long.
            skippedPoints += 1
            return
        }

        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            skippedPoints += 1
            return
        }

        currentPoints.append(TrackPoint(
            sessionID: 0,
            timestamp: timestamp,
            coordinate: coordinate,
            // GPX carries no accuracy. This stands in for it: good enough to
            // be accepted by the matcher's gate, conservative enough that a
            // single imported fix cannot dominate the chain.
            horizontalAccuracy: 15,
            speed: -1,
            course: -1,
            altitude: pendingElevation ?? 0
        ))
    }

    static func parseTimestamp(_ text: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
