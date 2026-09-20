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
        case insecureBaseURL
        case invalidURL
        case httpStatus(Int)
        case digestMismatch(expected: String, actual: String)
        case tooLarge(limit: Int64)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
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
        guard baseURL.scheme?.lowercased() == "https" else { throw DownloadError.insecureBaseURL }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DownloadError.invalidURL
        }
        // Built by appending path components rather than string concatenation,
        // so a catalog path can never escape the base URL or switch host.
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path
        guard let url = URL(string: city.pack.path, relativeTo: components.url)?.absoluteURL,
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
        guard digest.caseInsensitiveCompare(city.pack.sha256) == .orderedSame else {
            throw DownloadError.digestMismatch(expected: city.pack.sha256, actual: digest)
        }

        let decompressed = try GzipDecoder.decompress(compressed)
        return try installAtomically(decompressed, city: city)
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

    public func installedURL(for city: City) -> URL {
        packsDirectory.appendingPathComponent("\(city.id).v\(city.pack.version).sqlite")
    }

    public func isInstalled(_ city: City) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(for: city).path)
    }

    private func installAtomically(_ data: Data, city: City) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: packsDirectory, withIntermediateDirectories: true)

        let destination = installedURL(for: city)
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
        let url = installedURL(for: city)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Older versions of a city's pack, left behind after an update.
    public func staleFiles(keeping cities: [City]) -> [URL] {
        let keep = Set(cities.map { installedURL(for: $0).lastPathComponent })
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
