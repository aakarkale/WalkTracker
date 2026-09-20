import Foundation
import Compression

/// Writes gzip, for backups.
///
/// The mirror of `GzipDecoder`. A walk database compresses to a small
/// fraction of its size because coordinates repeat heavily, which matters for
/// a file the user will move through iCloud Drive or a share sheet.
public enum GzipEncoder {

    public enum Error: Swift.Error, LocalizedError {
        case deflateFailed

        public var errorDescription: String? {
            "The backup could not be compressed."
        }
    }

    /// Compresses `data` into a complete gzip stream.
    public static func compress(_ data: Data) throws -> Data {
        var output = Data()

        // RFC 1952 header: magic, DEFLATE, no flags, no timestamp, unknown OS.
        // A zero timestamp is deliberate: writing the clock in would make two
        // backups of identical data differ, which is confusing when comparing
        // files.
        output.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])

        output.append(try deflate(data))

        let crc = CRC32.checksum(data)
        let size = UInt32(truncatingIfNeeded: data.count)
        for value in [crc, size] {
            output.append(contentsOf: [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            ])
        }
        return output
    }

    private static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            // An empty DEFLATE stream is a single final stored block. The
            // framework will not produce one from no input, so it is written
            // out directly.
            return Data([0x03, 0x00])
        }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var stream = compression_stream(
            dst_ptr: buffer,
            dst_size: bufferSize,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.deflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()

        return try data.withUnsafeBytes { source -> Data in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                throw Error.deflateFailed
            }
            stream.src_ptr = base
            stream.src_size = source.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize

                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { throw Error.deflateFailed }
                default:
                    throw Error.deflateFailed
                }
            }
        }
    }
}
