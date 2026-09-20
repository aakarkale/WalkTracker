import Foundation
import Compression

/// Decompresses gzip city packs.
///
/// Apple's Compression framework inflates raw DEFLATE only, so the RFC 1952
/// gzip wrapper is parsed off by hand here. Every field is bounds-checked
/// before it is read, and the output is capped: a compressed file is
/// attacker-controlled input, and a few kilobytes of it can expand to
/// gigabytes if nothing stops it.
public enum GzipDecoder {

    public enum Error: Swift.Error, LocalizedError {
        case notGzip
        case unsupportedCompressionMethod
        case truncated
        case inflateFailed
        case tooLarge(limit: Int)
        case checksumMismatch
        case sizeMismatch

        public var errorDescription: String? {
            switch self {
            case .notGzip: return "The downloaded file is not a valid city pack archive."
            case .unsupportedCompressionMethod: return "The city pack archive uses an unsupported compression method."
            case .truncated: return "The city pack archive is incomplete."
            case .inflateFailed: return "The city pack archive could not be decompressed."
            case .tooLarge(let limit): return "The city pack expands beyond the \(limit) byte safety limit."
            case .checksumMismatch: return "The city pack failed its integrity check."
            case .sizeMismatch: return "The city pack is a different size than its archive declares."
            }
        }
    }

    /// Hard ceiling on decompressed output, regardless of what the catalog
    /// claims. No real city pack comes close.
    public static let absoluteSizeLimit = 512 * 1024 * 1024

    /// Inflates `data`, verifying the gzip trailer's CRC-32 and length.
    ///
    /// - Parameter expectedSize: declared uncompressed size, used to bound the
    ///   allocation. Clamped to `absoluteSizeLimit`.
    public static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        let limit = min(expectedSize.map { max($0, 1) * 2 } ?? absoluteSizeLimit, absoluteSizeLimit)

        // 10-byte minimum header plus 8-byte trailer.
        guard data.count >= 18 else { throw Error.truncated }

        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw Error.notGzip }
        guard bytes[2] == 0x08 else { throw Error.unsupportedCompressionMethod }

        let flags = bytes[3]
        // Reserved bits must be zero; anything else is malformed or hostile.
        guard flags & 0xE0 == 0 else { throw Error.notGzip }

        var cursor = 10

        if flags & 0x04 != 0 {              // FEXTRA
            guard cursor + 2 <= bytes.count else { throw Error.truncated }
            let extraLength = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2 + extraLength
            guard cursor <= bytes.count else { throw Error.truncated }
        }

        for bit in [UInt8(0x08), UInt8(0x10)] {   // FNAME, FCOMMENT
            guard flags & bit != 0 else { continue }
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count else { throw Error.truncated }
            cursor += 1
            // A field this long is a malformed archive, not a filename.
            guard cursor - start <= 4096 else { throw Error.notGzip }
        }

        if flags & 0x02 != 0 {              // FHCRC
            cursor += 2
            guard cursor <= bytes.count else { throw Error.truncated }
        }

        let deflateEnd = bytes.count - 8
        guard cursor < deflateEnd else { throw Error.truncated }

        let inflated = try inflate(data.subdata(in: cursor..<deflateEnd), limit: limit)

        // Trailer: CRC-32 then uncompressed size, both little-endian.
        let declaredCRC = UInt32(bytes[deflateEnd])
            | UInt32(bytes[deflateEnd + 1]) << 8
            | UInt32(bytes[deflateEnd + 2]) << 16
            | UInt32(bytes[deflateEnd + 3]) << 24
        let declaredSize = UInt32(bytes[deflateEnd + 4])
            | UInt32(bytes[deflateEnd + 5]) << 8
            | UInt32(bytes[deflateEnd + 6]) << 16
            | UInt32(bytes[deflateEnd + 7]) << 24

        guard UInt32(truncatingIfNeeded: inflated.count) == declaredSize else { throw Error.sizeMismatch }
        guard CRC32.checksum(inflated) == declaredCRC else { throw Error.checksumMismatch }

        return inflated
    }

    private static func inflate(_ deflated: Data, limit: Int) throws -> Data {
        guard !deflated.isEmpty else { throw Error.truncated }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.inflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()

        return try deflated.withUnsafeBytes { source -> Data in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                throw Error.inflateFailed
            }
            stream.src_ptr = base
            stream.src_size = source.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize

                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else { throw Error.tooLarge(limit: limit) }
                    output.append(buffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // No progress and no output means the stream is truncated,
                    // and looping again would spin forever.
                    if produced == 0 && stream.src_size == 0 { throw Error.truncated }
                default:
                    throw Error.inflateFailed
                }
            }
        }
    }
}

/// CRC-32 as specified by gzip (IEEE 802.3 polynomial, reflected).
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
