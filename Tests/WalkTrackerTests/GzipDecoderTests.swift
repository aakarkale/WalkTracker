//
//  GzipDecoderTests.swift
//
//  Covers GzipDecoder, which unwraps the RFC 1952 gzip container by hand
//  before handing the raw DEFLATE payload to the Compression framework.
//
//  A city pack arrives over the network, so every byte here is attacker
//  influenceable. These tests are therefore mostly about malformed input:
//  empty, truncated, wrong magic, an unsupported compression method, reserved
//  flag bits set, header fields that run off the end of the buffer. Every one
//  of them must throw a typed error rather than crash, read out of bounds, or
//  loop forever.
//
//  On the happy path there is one small hand-built archive below. Its payload
//  is a DEFLATE "stored" block, which is uncompressed data inside a valid
//  DEFLATE wrapper, so the archive can be written as literal bytes in this
//  file with no build-time tooling. It exercises the header walk, the inflate
//  call, and both trailer checks.
//
//  What it does NOT exercise is a real compressed stream: multiple 256 KB
//  output buffers, a Huffman coded payload, and the sizes a city runs to. That
//  needs a fixture file, and the right one is a genuine pack built by
//  Tools/citypack. Add `<city>.v1.sqlite.gz` to this target's resources and a
//  round trip test against it when the first real pack exists.
//

import Foundation
import XCTest
@testable import WalkTracker

final class GzipDecoderTests: XCTestCase {

    // MARK: - Fixtures

    /// A 10 byte gzip header: magic, method 8 (DEFLATE), flags, a zero mtime,
    /// no extra flags, and OS 3 (Unix), which is what gzip itself writes.
    private func header(flags: UInt8 = 0, method: UInt8 = 0x08, magic: [UInt8] = [0x1f, 0x8b]) -> [UInt8] {
        magic + [method, flags, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]
    }

    /// CRC-32 and uncompressed size, both little endian.
    private func trailer(crc: UInt32, size: UInt32) -> [UInt8] {
        [
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 24) & 0xFF),
            UInt8(size & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 24) & 0xFF)
        ]
    }

    /// "WalkTracker" as a single final DEFLATE stored block: BFINAL set with
    /// block type 00, then the length, then its ones complement, then the
    /// literal bytes. RFC 1951 section 3.2.4.
    private let payload = Array("WalkTracker".utf8)

    private var storedBlock: [UInt8] {
        [0x01, 0x0B, 0x00, 0xF4, 0xFF] + payload
    }

    /// CRC-32 of "WalkTracker" under the gzip polynomial, computed
    /// independently (zlib.crc32) rather than with the implementation under
    /// test, so the two can disagree.
    private let payloadCRC: UInt32 = 0xCD43_1415

    private var validArchive: Data {
        Data(header() + storedBlock + trailer(crc: payloadCRC, size: UInt32(payload.count)))
    }

    // MARK: - Assertion helper

    private func assertThrows(
        _ data: Data,
        _ description: String,
        expectedSize: Int? = nil,
        matches: (GzipDecoder.Error) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try GzipDecoder.decompress(data, expectedSize: expectedSize),
            description,
            file: file,
            line: line
        ) { error in
            guard let gzipError = error as? GzipDecoder.Error else {
                XCTFail("\(description): threw \(error), which is not a GzipDecoder.Error", file: file, line: line)
                return
            }
            XCTAssertTrue(matches(gzipError), "\(description): threw \(gzipError)", file: file, line: line)
        }
    }

    private func isTruncated(_ error: GzipDecoder.Error) -> Bool {
        if case .truncated = error { return true }
        return false
    }

    private func isNotGzip(_ error: GzipDecoder.Error) -> Bool {
        if case .notGzip = error { return true }
        return false
    }

    // MARK: - Too short

    func testEmptyInputThrows() {
        assertThrows(Data(), "empty input", matches: isTruncated)
    }

    func testInputShorterThanAHeaderAndTrailerThrows() {
        // 18 bytes is the absolute minimum: a 10 byte header and an 8 byte
        // trailer. Anything shorter cannot be read at all.
        for count in [1, 2, 9, 10, 17] {
            let short = Data(Array(repeating: UInt8(0x1f), count: count))
            assertThrows(short, "input of \(count) bytes", matches: isTruncated)
        }
    }

    func testHeaderAndTrailerWithNoPayloadThrows() {
        // Exactly 18 bytes, so the length check passes, but there is no
        // DEFLATE data between the header and the trailer.
        let data = Data(header() + trailer(crc: 0, size: 0))
        XCTAssertEqual(data.count, 18)
        assertThrows(data, "header and trailer with no payload", matches: isTruncated)
    }

    // MARK: - Bad header

    func testWrongMagicThrows() {
        let data = Data(header(magic: [0x00, 0x00]) + storedBlock + trailer(crc: payloadCRC, size: 11))
        assertThrows(data, "zeroed magic", matches: isNotGzip)

        // A zip file, which is a plausible thing to be handed by mistake.
        let zip = Data(header(magic: [0x50, 0x4B]) + storedBlock + trailer(crc: payloadCRC, size: 11))
        assertThrows(zip, "zip magic", matches: isNotGzip)
    }

    func testUnsupportedCompressionMethodThrows() {
        // Only method 8 (DEFLATE) has ever been used by gzip. The others are
        // reserved for compression methods that were never standardised.
        for method: UInt8 in [0x00, 0x07, 0x09, 0xFF] {
            let data = Data(header(method: method) + storedBlock + trailer(crc: payloadCRC, size: 11))
            assertThrows(data, "compression method \(method)") { error in
                if case .unsupportedCompressionMethod = error { return true }
                return false
            }
        }
    }

    func testReservedFlagBitsThrow() {
        // Bits 5, 6 and 7 of FLG are reserved and must be zero. A decoder that
        // ignored them would be guessing at the layout of the header.
        for flags: UInt8 in [0x20, 0x40, 0x80, 0xE0] {
            let data = Data(header(flags: flags) + storedBlock + trailer(crc: payloadCRC, size: 11))
            assertThrows(data, "reserved flag bits \(flags)", matches: isNotGzip)
        }
    }

    func testExtraFieldRunningPastTheEndThrows() {
        // FEXTRA with a declared length of 65535 in a 34 byte file.
        let data = Data(header(flags: 0x04) + [0xFF, 0xFF] + storedBlock + trailer(crc: payloadCRC, size: 11))
        assertThrows(data, "extra field longer than the file", matches: isTruncated)
    }

    func testUnterminatedFileNameThrows() {
        // FNAME is a zero terminated string. Without a terminator the scan
        // runs to the end of the buffer, which must be caught rather than
        // read past.
        let filler = [UInt8](repeating: 0x41, count: 24)
        let data = Data(header(flags: 0x08) + filler)
        assertThrows(data, "unterminated file name", matches: isTruncated)
    }

    func testUnterminatedCommentThrows() {
        let filler = [UInt8](repeating: 0x41, count: 24)
        let data = Data(header(flags: 0x10) + filler)
        assertThrows(data, "unterminated comment", matches: isTruncated)
    }

    func testHeaderChecksumFlagLeavingNoRoomForPayloadThrows() {
        // FHCRC adds two bytes, which pushes the cursor past the start of the
        // trailer in a minimal file.
        let data = Data(header(flags: 0x02) + trailer(crc: 0, size: 0))
        assertThrows(data, "header CRC with no payload", matches: isTruncated)
    }

    // MARK: - Bad payload

    func testGarbagePayloadThrows() {
        let garbage = [UInt8](repeating: 0xFF, count: 12)
        let data = Data(header() + garbage + trailer(crc: payloadCRC, size: 11))
        // Either the inflate fails outright or it produces something that
        // fails the trailer checks. Both are correct; neither may crash.
        assertThrows(data, "garbage payload") { _ in true }
    }

    func testTruncatedPayloadThrows() {
        // The stored block declares 11 bytes but only 4 follow.
        let cut = Array(storedBlock.prefix(9))
        let data = Data(header() + cut + trailer(crc: payloadCRC, size: 11))
        assertThrows(data, "truncated stored block") { _ in true }
    }

    // MARK: - Trailer verification

    func testValidArchiveRoundTrips() throws {
        // See the file header: synthetic, but a real archive by the standard.
        let inflated = try GzipDecoder.decompress(validArchive)
        XCTAssertEqual(inflated, Data(payload))
        XCTAssertEqual(String(data: inflated, encoding: .utf8), "WalkTracker")
    }

    func testDeclaredSizeIsVerified() {
        // The trailer claims 99 bytes; 11 came out.
        let data = Data(header() + storedBlock + trailer(crc: payloadCRC, size: 99))
        assertThrows(data, "wrong declared size") { error in
            if case .sizeMismatch = error { return true }
            return false
        }
    }

    func testChecksumIsVerified() {
        // Right size, wrong CRC: the case where content has been substituted
        // for something of the same length.
        let data = Data(header() + storedBlock + trailer(crc: 0xDEAD_BEEF, size: 11))
        assertThrows(data, "wrong checksum") { error in
            if case .checksumMismatch = error { return true }
            return false
        }
    }

    // MARK: - Output limit

    func testExpectedSizeBoundsTheOutput() {
        // A decompression bomb is a few kilobytes that expand to gigabytes.
        // The declared size from the catalog caps the allocation.
        assertThrows(validArchive, "output beyond the declared size", expectedSize: 1) { error in
            if case .tooLarge = error { return true }
            return false
        }
    }

    func testExpectedSizeThatFitsIsAccepted() throws {
        let inflated = try GzipDecoder.decompress(validArchive, expectedSize: payload.count)
        XCTAssertEqual(inflated.count, payload.count)
    }

    func testAbsoluteLimitIsSane() {
        // The ceiling applies regardless of what the catalog claims. It is
        // large enough for any real city and far below anything that would
        // exhaust a device.
        XCTAssertEqual(GzipDecoder.absoluteSizeLimit, 512 * 1024 * 1024)
    }

    // MARK: - Fuzzing the header

    func testRandomBytesNeverCrash() {
        // Not a correctness test: a crash guard. Every one of these should
        // throw, and none should trap, hang or read out of bounds.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let count = Int.random(in: 0...64, using: &generator)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // Half of them get a valid magic, so the header walk is reached
            // rather than every case failing at the first check.
            if count >= 2, Bool.random(using: &generator) {
                bytes[0] = 0x1f
                bytes[1] = 0x8b
                if count >= 3 { bytes[2] = 0x08 }
                if count >= 4 { bytes[3] &= 0x1F }
            }
            XCTAssertThrowsError(try GzipDecoder.decompress(Data(bytes))) { error in
                XCTAssertTrue(error is GzipDecoder.Error, "threw \(error)")
            }
        }
    }
}
