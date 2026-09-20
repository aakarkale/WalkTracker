import Foundation

/// Writes recorded walks out as GPX.
///
/// Export exists because the alternative is a lock-in: someone who has spent a
/// year mapping their city should be able to take that with them. It writes
/// the raw trace rather than the derived coverage, since the trace is the part
/// that is genuinely theirs and is portable to any other tool.
public struct GPXExporter {

    private let sessionStore: SessionStore

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Exports sessions to a GPX file, one track per session.
    ///
    /// Written incrementally to a file rather than built in memory: a heavy
    /// user's history runs to hundreds of thousands of points, and holding the
    /// whole document as a String would be a straightforward way to be killed
    /// for memory use.
    @discardableResult
    public func export(sessions: [WalkSession], to url: URL) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try write(handle, Self.header)

        for session in sessions {
            let points = try sessionStore.points(sessionID: session.id)
            guard !points.isEmpty else { continue }

            try write(handle, """
              <trk>
                <name>\(Self.escape(Self.trackName(for: session)))</name>
                <type>walking</type>
                <trkseg>\n
            """)

            for point in points {
                try write(handle, """
                      <trkpt lat="\(Self.coordinate(point.coordinate.latitude))" lon="\(Self.coordinate(point.coordinate.longitude))">
                        <ele>\(String(format: "%.1f", point.altitude))</ele>
                        <time>\(Self.timestamp.string(from: point.timestamp))</time>
                      </trkpt>\n
                """)
            }

            try write(handle, "    </trkseg>\n  </trk>\n")
        }

        try write(handle, "</gpx>\n")
        return url
    }

    /// A filename-safe default for the exported document.
    public static func suggestedFilename(cityID: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let city = (cityID ?? "walks").replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "-",
            options: .regularExpression
        )
        return "walktracker-\(city)-\(formatter.string(from: date)).gpx"
    }

    // MARK: - Internals

    private static let header = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="WalkTracker" xmlns="http://www.topografix.com/GPX/1/1">\n
    """

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func trackName(for session: WalkSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(session.cityID) \(formatter.string(from: session.startedAt))"
    }

    /// Seven decimal places is about 1 cm, past any GPS resolution, and the
    /// POSIX locale keeps a device set to a comma decimal separator from
    /// writing coordinates no other tool can read.
    private static func coordinate(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Escapes text for XML.
    ///
    /// City names come out of a downloaded pack, so they are untrusted input
    /// to this document. Without escaping, a crafted name could close the tag
    /// and inject arbitrary XML into a file the user then opens elsewhere.
    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default:
                // Control characters are not representable in XML 1.0 at all,
                // so they are dropped rather than escaped.
                if let ascii = character.asciiValue, ascii < 0x20,
                   character != "\n", character != "\t", character != "\r" {
                    continue
                }
                output.append(character)
            }
        }
        return output
    }

    private func write(_ handle: FileHandle, _ string: String) throws {
        guard let data = string.data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }
}
