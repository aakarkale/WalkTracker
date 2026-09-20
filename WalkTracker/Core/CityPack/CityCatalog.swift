import Foundation

/// The bundled list of supported cities.
///
/// Ships inside the app binary rather than being fetched, because it carries
/// the SHA-256 digests that every downloaded pack is checked against. A
/// catalog fetched at runtime would let whoever serves it choose those
/// digests, which would defeat the point of having them.
public struct CityCatalog: Decodable, Sendable {

    public let catalogVersion: Int
    public let packBaseURL: URL
    public let cities: [City]

    private enum CodingKeys: String, CodingKey {
        case catalogVersion, packBaseURL, cities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.catalogVersion = try container.decode(Int.self, forKey: .catalogVersion)

        let urlString = try container.decode(String.self, forKey: .packBaseURL)
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            throw DecodingError.dataCorruptedError(
                forKey: .packBaseURL,
                in: container,
                debugDescription: "Pack base URL must be an absolute https URL"
            )
        }
        self.packBaseURL = url
        self.cities = try container.decode([CityEntry].self, forKey: .cities).map(\.city)
    }

    /// Wire format, kept separate from the domain type so the JSON shape can
    /// change without the rest of the app noticing.
    private struct CityEntry: Decodable {
        let city: City

        private enum Keys: String, CodingKey {
            case id, name, country, countryCode, center, cameraBounds, pack
        }
        private struct Point: Decodable { let latitude, longitude: Double }
        private struct Bounds: Decodable {
            let minLatitude, minLongitude, maxLatitude, maxLongitude: Double
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let center = try c.decode(Point.self, forKey: .center)
            let bounds = try c.decode(Bounds.self, forKey: .cameraBounds)
            self.city = City(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                country: try c.decode(String.self, forKey: .country),
                countryCode: try c.decode(String.self, forKey: .countryCode),
                cameraBounds: BoundingBox(
                    minLatitude: bounds.minLatitude,
                    minLongitude: bounds.minLongitude,
                    maxLatitude: bounds.maxLatitude,
                    maxLongitude: bounds.maxLongitude
                ),
                center: Coordinate(latitude: center.latitude, longitude: center.longitude),
                pack: try c.decodeIfPresent(City.PackDescriptor.self, forKey: .pack)
            )
        }
    }

    // MARK: - Loading

    public enum CatalogError: Error, LocalizedError {
        case missingResource

        public var errorDescription: String? {
            "The bundled city list is missing or unreadable."
        }
    }

    public static func load(from bundle: Bundle = .main, resource: String = "cities") throws -> CityCatalog {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(CityCatalog.self, from: Data(contentsOf: url))
    }

    public func city(id: String) -> City? {
        cities.first { $0.id == id }
    }

    /// Cities with street data ready to download.
    public var available: [City] {
        cities.filter(\.isAvailable).sorted { $0.name < $1.name }
    }

    /// Cities listed but not yet built.
    public var pending: [City] {
        cities.filter { !$0.isAvailable }.sorted { $0.name < $1.name }
    }

    /// The city whose camera bounds contain `coordinate`, nearest centre first.
    ///
    /// Used to offer the right city on launch. Bounding boxes overlap for
    /// nearby cities, so the closest centre wins.
    public func city(containing coordinate: Coordinate) -> City? {
        cities
            .filter { $0.cameraBounds.contains(coordinate) }
            .min { GeoMath.haversine($0.center, coordinate) < GeoMath.haversine($1.center, coordinate) }
    }
}
