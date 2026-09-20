import Foundation

/// A city the app can track, as described by the bundled catalog.
///
/// The catalog ships with the binary and holds only metadata. The street
/// geometry lives in a separately downloaded city pack, because twenty cities
/// of street data is far too large to embed in an app binary.
public struct City: Identifiable, Equatable, Codable, Sendable {
    public let id: String            // stable slug, e.g. "new-york"
    public let name: String
    public let country: String
    public let countryCode: String   // ISO 3166-1 alpha-2
    /// Coarse box used only to frame the map camera before a pack is
    /// installed. The authoritative boundary ships inside the pack itself.
    public let cameraBounds: BoundingBox
    public let center: Coordinate
    /// Pack metadata, used to download and verify the street data.
    ///
    /// Nil until a pack has actually been built for this city. The digest and
    /// sizes can only come from a real build, so a city ships as "not yet
    /// available" rather than carrying invented values that would fail
    /// verification on first download.
    public let pack: PackDescriptor?

    public struct PackDescriptor: Equatable, Codable, Sendable {
        /// Schema/content revision. Bumped when a pack is rebuilt.
        public let version: Int
        /// Path relative to the configured pack base URL.
        public let path: String
        /// Lowercase hex SHA-256 of the compressed pack file.
        public let sha256: String
        /// Compressed size in bytes, shown to the user before download.
        public let compressedBytes: Int64
        /// Number of walkable blocks, shown in the city list.
        public let segmentCount: Int
        /// Total walkable length in metres: the denominator of the percentage.
        public let totalLengthMetres: Double

        public init(
            version: Int,
            path: String,
            sha256: String,
            compressedBytes: Int64,
            segmentCount: Int,
            totalLengthMetres: Double
        ) {
            self.version = version
            self.path = path
            self.sha256 = sha256
            self.compressedBytes = compressedBytes
            self.segmentCount = segmentCount
            self.totalLengthMetres = totalLengthMetres
        }
    }

    public init(
        id: String,
        name: String,
        country: String,
        countryCode: String,
        cameraBounds: BoundingBox,
        center: Coordinate,
        pack: PackDescriptor?
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.countryCode = countryCode
        self.cameraBounds = cameraBounds
        self.center = center
        self.pack = pack
    }

    /// Whether street data exists to download for this city.
    public var isAvailable: Bool { pack != nil }
}

/// A named sub-area of a city, used for the neighbourhood leaderboard.
public struct District: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let bounds: BoundingBox
    public let segmentCount: Int
    public let totalLengthMetres: Double

    public init(id: Int64, name: String, bounds: BoundingBox, segmentCount: Int, totalLengthMetres: Double) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.segmentCount = segmentCount
        self.totalLengthMetres = totalLengthMetres
    }
}
