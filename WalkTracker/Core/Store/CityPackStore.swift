import Foundation

/// Read-only access to one installed city pack.
///
/// Packs are treated as untrusted input even though the app downloads them
/// itself: the file arrives over the network, sits in a writable container,
/// and is parsed on a hot path. Every field read from it is range-checked, and
/// the connection is opened read-only so a malformed pack cannot write
/// anything back.
public final class CityPackStore: SegmentIndex {

    public struct Meta: Equatable, Sendable {
        public let schemaVersion: Int
        public let cityID: String
        public let cityName: String
        public let builtAt: String
        public let osmExtract: String
        public let segmentCount: Int
        public let totalLengthMetres: Double
        public let bounds: BoundingBox
    }

    /// Schema versions this build understands. A pack outside this range is
    /// rejected rather than parsed on a guess.
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...1

    public let meta: Meta
    private let database: SQLiteDatabase

    /// Decoded segments, keyed by id. The matcher asks for the same handful of
    /// blocks over and over as the user walks down a street, so decoding the
    /// geometry blob every time would dominate the tracking cost.
    private var cache: [Int64: StreetSegment] = [:]
    private var cacheOrder: [Int64] = []
    private let cacheLimit = 4_000
    private let cacheLock = NSLock()

    public enum PackError: Error, LocalizedError {
        case unsupportedSchema(Int)
        case missingMeta(String)
        case corruptGeometry(Int64)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let v):
                return "City pack uses schema version \(v), which this version of the app cannot read."
            case .missingMeta(let key):
                return "City pack is missing required metadata: \(key)."
            case .corruptGeometry(let id):
                return "City pack contains unreadable geometry for segment \(id)."
            }
        }
    }

    public init(path: String) throws {
        self.database = try SQLiteDatabase(path: path, readOnly: true)

        let rows = try database.query("SELECT key, value FROM meta") { row in
            (row.string(0) ?? "", row.string(1) ?? "")
        }
        let values = Dictionary(rows, uniquingKeysWith: { _, last in last })

        func require(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw PackError.missingMeta(key) }
            return value
        }

        let schemaVersion = Int(try require("schema_version")) ?? 0
        guard Self.supportedSchemaVersions.contains(schemaVersion) else {
            throw PackError.unsupportedSchema(schemaVersion)
        }

        self.meta = Meta(
            schemaVersion: schemaVersion,
            cityID: try require("city_id"),
            cityName: try require("city_name"),
            builtAt: values["built_at"] ?? "",
            osmExtract: values["osm_extract"] ?? "",
            segmentCount: Int(values["segment_count"] ?? "") ?? 0,
            totalLengthMetres: Double(values["total_length_m"] ?? "") ?? 0,
            bounds: BoundingBox(
                minLatitude: Double(values["min_lat"] ?? "") ?? 0,
                minLongitude: Double(values["min_lon"] ?? "") ?? 0,
                maxLatitude: Double(values["max_lat"] ?? "") ?? 0,
                maxLongitude: Double(values["max_lon"] ?? "") ?? 0
            )
        )
    }

    // MARK: - SegmentIndex

    public func segments(near coordinate: Coordinate, radiusMetres: Double) -> [StreetSegment] {
        let box = BoundingBox(
            minLatitude: coordinate.latitude,
            minLongitude: coordinate.longitude,
            maxLatitude: coordinate.latitude,
            maxLongitude: coordinate.longitude
        ).expanded(byMetres: radiusMetres)
        return segments(in: box)
    }

    public func segment(id: Int64) -> StreetSegment? {
        if let cached = cached(id) { return cached }
        let rows = (try? database.query(Self.selectByID, [.integer(id)], decode: decodeRow)) ?? []
        guard let segment = rows.compactMap({ $0 }).first else { return nil }
        store(segment)
        return segment
    }

    // MARK: - Spatial queries

    /// All walkable blocks intersecting `box`.
    ///
    /// Goes through the R*Tree index. A full table scan over a city with tens
    /// of thousands of blocks would make both tracking and map redraws
    /// unusable.
    public func segments(in box: BoundingBox, limit: Int = 20_000) -> [StreetSegment] {
        let parameters: [SQLiteDatabase.Value] = [
            .real(box.minLongitude), .real(box.maxLongitude),
            .real(box.minLatitude), .real(box.maxLatitude),
            .integer(Int64(limit))
        ]
        let rows = (try? database.query(Self.selectInBox, parameters, decode: decodeRow)) ?? []
        let segments = rows.compactMap { $0 }
        for segment in segments { store(segment) }
        return segments
    }

    public func districts() -> [District] {
        let sql = """
        SELECT id, name, min_lat, min_lon, max_lat, max_lon, segment_count, total_length_m
        FROM district ORDER BY name
        """
        return (try? database.query(sql) { row in
            District(
                id: row.int(0),
                name: row.string(1) ?? "",
                bounds: BoundingBox(
                    minLatitude: row.double(2),
                    minLongitude: row.double(3),
                    maxLatitude: row.double(4),
                    maxLongitude: row.double(5)
                ),
                segmentCount: Int(row.int(6)),
                totalLengthMetres: row.double(7)
            )
        }) ?? []
    }

    /// Total walkable length, excluding classes left out of the default
    /// percentage unless `includeOptional` is set.
    public func totalLength(includeOptional: Bool) -> Double {
        if includeOptional {
            let rows = (try? database.query("SELECT SUM(length_m) FROM segment") { $0.double(0) }) ?? []
            return rows.first ?? 0
        }
        let excluded = WayClass.allCases.filter(\.isOptionalByDefault).map { "'\($0.rawValue)'" }.joined(separator: ",")
        let rows = (try? database.query("SELECT SUM(length_m) FROM segment WHERE class NOT IN (\(excluded))") {
            $0.double(0)
        }) ?? []
        return rows.first ?? 0
    }

    // MARK: - Decoding

    private static let columns = "s.id, s.way_id, s.name, s.class, s.start_node, s.end_node, s.district_id, s.geometry"

    private static let selectByID = "SELECT \(columns) FROM segment s WHERE s.id = ?"

    private static let selectInBox = """
    SELECT \(columns) FROM segment s
    JOIN segment_rtree r ON r.id = s.id
    WHERE r.max_lon >= ? AND r.min_lon <= ? AND r.max_lat >= ? AND r.min_lat <= ?
    LIMIT ?
    """

    private func decodeRow(_ row: SQLiteDatabase.Row) -> StreetSegment? {
        let id = row.int(0)
        if let cached = cached(id) { return cached }

        guard let blob = row.blob(7),
              let coordinates = Self.decodeGeometry(blob),
              coordinates.count >= 2 else {
            // A single unreadable block should not take down a whole city.
            return nil
        }

        return StreetSegment(
            id: id,
            wayID: row.int(1),
            name: row.string(2),
            wayClass: WayClass(rawValue: row.string(3) ?? "") ?? .unclassified,
            startNodeID: row.int(4),
            endNodeID: row.int(5),
            geometry: Polyline(coordinates: coordinates),
            districtID: row.optionalInt(6)
        )
    }

    /// Decodes the pack geometry blob: a little-endian `uint16` point count,
    /// then that many `int32` latitudes scaled by 1e7, then the longitudes.
    ///
    /// Returns nil rather than throwing on anything unexpected. The blob is
    /// attacker-influenceable in principle, so every length is checked against
    /// the actual buffer before any read.
    static func decodeGeometry(_ data: Data) -> [Coordinate]? {
        guard data.count >= 2 else { return nil }

        return data.withUnsafeBytes { buffer -> [Coordinate]? in
            guard let base = buffer.baseAddress else { return nil }

            let count = Int(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt16.self)))
            guard count >= 2 else { return nil }

            let expected = 2 + count * 8
            guard buffer.count == expected else { return nil }

            var coordinates: [Coordinate] = []
            coordinates.reserveCapacity(count)

            let latOffset = 2
            let lonOffset = 2 + count * 4

            for i in 0..<count {
                let latRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: latOffset + i * 4, as: Int32.self))
                let lonRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: lonOffset + i * 4, as: Int32.self))
                let coordinate = Coordinate(
                    latitude: Double(latRaw) / 1e7,
                    longitude: Double(lonRaw) / 1e7
                )
                guard coordinate.latitude >= -90, coordinate.latitude <= 90,
                      coordinate.longitude >= -180, coordinate.longitude <= 180 else { return nil }
                coordinates.append(coordinate)
            }
            return coordinates
        }
    }

    // MARK: - Cache

    private func cached(_ id: Int64) -> StreetSegment? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[id]
    }

    private func store(_ segment: StreetSegment) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cache[segment.id] == nil else { return }
        cache[segment.id] = segment
        cacheOrder.append(segment.id)
        // Simple FIFO eviction. A true LRU would need a touch on every read,
        // and the access pattern here is a moving window rather than a set of
        // hot favourites, so insertion order is the right proxy.
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }
}
