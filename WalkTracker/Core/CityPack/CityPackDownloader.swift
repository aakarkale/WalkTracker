import Foundation
import CryptoKit

/// Downloads, verifies and installs city packs.
///
/// The security posture here is that the content delivery network is not
/// trusted. Every pack is checked against a SHA-256 digest that ships inside
/// the signed app binary, before it is decompressed and before SQLite is
/// pointed at it. A CDN that is compromised, misconfigured, or intercepted can
/// therefore serve a wrong file but cannot get it opened.
public final class CityPackDownloader: NSObject {

    public enum DownloadError: Error, LocalizedError {
        case noPackAvailable(cityName: String)
        case localPackUnreadable(String)
        case localPackForDifferentCity(found: String)
        case insecureBaseURL
        case invalidURL
        case httpStatus(Int)
        case digestMismatch(expected: String, actual: String)
        case tooLarge(limit: Int64)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPackAvailable(let cityName):
                return "Street data for \(cityName) has not been published yet."
            case .localPackUnreadable(let reason):
                return "That file could not be read as a city pack: \(reason)"
            case .localPackForDifferentCity(let found):
                return "That pack contains street data for \(found)."
            case .insecureBaseURL:
                return "City packs can only be downloaded over HTTPS."
            case .invalidURL:
                return "The city pack address is not valid."
            case .httpStatus(let code):
                return "The city pack server responded with status \(code)."
            case .digestMismatch:
                return "The downloaded city pack did not match its expected contents and was discarded."
            case .tooLarge(let limit):
                return "The city pack exceeds the \(limit) byte download limit."
            case .installFailed(let reason):
                return "The city pack could not be installed: \(reason)"
            }
        }
    }

    public struct Progress: Equatable, Sendable {
        public let bytesReceived: Int64
        public let bytesExpected: Int64
        public var fraction: Double {
            bytesExpected > 0 ? min(1, Double(bytesReceived) / Double(bytesExpected)) : 0
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let packsDirectory: URL

    /// Ceiling on the compressed download, independent of what the catalog
    /// claims, so a hostile redirect cannot fill the device.
    private static let maxCompressedBytes: Int64 = 256 * 1024 * 1024

    public init(baseURL: URL, packsDirectory: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.packsDirectory = packsDirectory
        self.session = session
        super.init()
    }

    // MARK: - Install

    /// Downloads and installs a city's pack, returning the installed file URL.
    public func install(
        city: City,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        // A city in the catalog with no pack descriptor has no street data
        // built yet. There is nothing to fetch and nothing to verify against,
        // so this fails here rather than constructing a URL from nothing.
        guard let pack = city.pack else {
            throw DownloadError.noPackAvailable(cityName: city.name)
        }
        guard baseURL.scheme?.lowercased() == "https" else { throw DownloadError.insecureBaseURL }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DownloadError.invalidURL
        }
        // Built by appending path components rather than string concatenation,
        // so a catalog path can never escape the base URL or switch host.
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path
        guard let url = URL(string: pack.path, relativeTo: components.url)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host == baseURL.host else {
            throw DownloadError.invalidURL
        }

        let compressed = try await download(url, onProgress: onProgress)

        guard Int64(compressed.count) <= Self.maxCompressedBytes else {
            throw DownloadError.tooLarge(limit: Self.maxCompressedBytes)
        }

        // Verified before anything parses the bytes.
        let digest = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(pack.sha256) == .orderedSame else {
            throw DownloadError.digestMismatch(expected: pack.sha256, actual: digest)
        }

        let decompressed = try GzipDecoder.decompress(compressed)
        return try installAtomically(decompressed, city: city, version: pack.version)
    }

    private func download(
        _ url: URL,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }

        let expected = response.expectedContentLength
        if expected > Self.maxCompressedBytes {
            throw DownloadError.tooLarge(limit: Self.maxCompressedBytes)
        }

        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var received: Int64 = 0
        var lastReport: Int64 = 0

        for try await byte in bytes {
            data.append(byte)
            received += 1
            // The declared length is a hint from the server, so the cap is
            // enforced against bytes actually received.
            if received > Self.maxCompressedBytes {
                throw DownloadError.tooLarge(limit: Self.maxCompressedBytes)
            }
            if received - lastReport >= 64 * 1024 {
                lastReport = received
                onProgress?(Progress(bytesReceived: received, bytesExpected: expected))
            }
        }
        onProgress?(Progress(bytesReceived: received, bytesExpected: max(expected, received)))
        return data
    }

    // MARK: - Filesystem

    /// Where a city's pack lives once installed, or nil when there is none.
    ///
    /// A side-loaded pack wins over a published one. Someone who has gone to
    /// the trouble of building a pack and choosing the file means to use it,
    /// and it is usually newer than whatever is published.
    public func installedURL(for city: City) -> URL? {
        let local = localURL(cityID: city.id)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let pack = city.pack else { return nil }
        return installedURL(cityID: city.id, version: pack.version)
    }

    private func installedURL(cityID: String, version: Int) -> URL {
        packsDirectory.appendingPathComponent("\(cityID).v\(version).sqlite")
    }

    /// Side-loaded packs get their own filename, so a glance at the directory
    /// says which packs were verified against a published digest and which
    /// were taken on the user's word.
    private func localURL(cityID: String) -> URL {
        packsDirectory.appendingPathComponent("\(cityID).local.sqlite")
    }

    public func hasLocalPack(_ city: City) -> Bool {
        FileManager.default.fileExists(atPath: localURL(cityID: city.id).path)
    }

    public func isInstalled(_ city: City) -> Bool {
        guard let url = installedURL(for: city) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func installAtomically(_ data: Data, city: City, version: Int) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: packsDirectory, withIntermediateDirectories: true)

        let destination = installedURL(cityID: city.id, version: version)
        let temporary = packsDirectory.appendingPathComponent("\(city.id).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: .atomic)

            // Opened read-only before it is moved into place: a file that is
            // not a readable pack of a supported schema never becomes the
            // installed one.
            _ = try CityPackStore(path: temporary.path)

            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw DownloadError.installFailed(error.localizedDescription)
        }

        // Packs are re-downloadable, so keeping them out of iCloud backups
        // saves the user's storage without costing them anything.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(resource)

        return destination
    }

    /// Removes an installed pack. The user's walk history is untouched: it
    /// lives in a different database entirely.
    public func uninstall(_ city: City) throws {
        for url in [localURL(cityID: city.id), city.pack.map { installedURL(cityID: city.id, version: $0.version) }].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Side-loading

    /// What a side-loaded pack turned out to contain.
    public struct LocalPack: Equatable, Sendable {
        public let cityID: String
        public let cityName: String
        public let segmentCount: Int
        public let totalLengthMetres: Double
        /// Digest of the uncompressed pack. Identifies this particular pack,
        /// which is what tells the app a different one has been installed and
        /// coverage must be rebuilt.
        public let sha256: String
        public let installedURL: URL
    }

    /// Installs a pack from a file the user chose.
    ///
    /// This exists because a pack could otherwise only arrive by HTTPS
    /// download, which meant anyone wanting to try a pack they had just built
    /// had to host it for themselves first. That is a silly amount of
    /// ceremony for a local test.
    ///
    /// The tradeoff is explicit: there is no published digest to check the
    /// file against, because the catalog has none for an unbuilt city. The
    /// file is therefore trusted to the extent that the user chose it, and no
    /// further. Everything that can still be checked is: it must decompress,
    /// it must open as a pack of a schema this build understands, it must
    /// carry the city it claims, and it is opened read-only like any other.
    public func installLocalPack(at fileURL: URL, expecting city: City) throws -> LocalPack {
        let manager = FileManager.default
        try manager.createDirectory(at: packsDirectory, withIntermediateDirectories: true)

        let contents = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard contents.count <= Self.maxCompressedBytes else {
            throw DownloadError.tooLarge(limit: Self.maxCompressedBytes)
        }

        // Accepts the file either as the pipeline writes it or already
        // decompressed, since decompressing first is a natural thing to do.
        let raw: Data
        if contents.count >= 2,
           contents[contents.startIndex] == 0x1f,
           contents[contents.startIndex + 1] == 0x8b {
            raw = try GzipDecoder.decompress(contents)
        } else {
            raw = contents
        }

        let staging = packsDirectory.appendingPathComponent("\(city.id).\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: staging) }
        try raw.write(to: staging, options: .atomic)

        let store: CityPackStore
        do {
            store = try CityPackStore(path: staging.path)
        } catch {
            throw DownloadError.localPackUnreadable(error.localizedDescription)
        }

        // A pack for the wrong city would quietly credit streets in one place
        // against a percentage for another.
        guard store.meta.cityID == city.id else {
            throw DownloadError.localPackForDifferentCity(
                found: store.meta.cityName.isEmpty ? store.meta.cityID : store.meta.cityName
            )
        }

        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let destination = localURL(cityID: city.id)

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(resource)

        return LocalPack(
            cityID: store.meta.cityID,
            cityName: store.meta.cityName,
            segmentCount: store.meta.segmentCount,
            totalLengthMetres: store.meta.totalLengthMetres,
            sha256: digest,
            installedURL: destination
        )
    }

    /// Older versions of a city's pack, left behind after an update.
    public func staleFiles(keeping cities: [City]) -> [URL] {
        let keep = Set(cities.compactMap { installedURL(for: $0)?.lastPathComponent })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: packsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { url in
            (url.pathExtension == "sqlite" || url.pathExtension == "tmp")
                && !keep.contains(url.lastPathComponent)
        }
    }
}
