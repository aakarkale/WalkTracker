//
//  CityCatalogTests.swift
//
//  Covers CityCatalog, including the real WalkTracker/Resources/cities.json
//  that ships in the app bundle. The catalog is copied into this test bundle
//  as a resource (see project.yml) so these tests check the file the app
//  actually ships rather than a fixture that could drift away from it.
//
//  Two things are being defended here.
//
//  The catalog is the trust anchor for city packs: it carries the SHA-256 of
//  every pack, and a pack is verified against it before anything parses the
//  bytes. That only holds if the catalog itself cannot be swapped, which is
//  why it ships inside the signed binary and why its pack base URL is
//  required to be https. A plain http base URL is rejected at decode time
//  rather than at download time, so a bad catalog fails loudly at launch
//  instead of quietly downgrading transport security later.
//
//  Every pack is currently null. That is deliberate: a digest and a size can
//  only come from a real build, and invented values would fail verification
//  on first download. When Tools/citypack produces the first real pack, the
//  "every pack is nil" assertion below is the one to update, and it should be
//  updated to check the shape of the descriptor rather than deleted.
//

import Foundation
import XCTest
@testable import WalkTracker

final class CityCatalogTests: XCTestCase {

    private var catalog: CityCatalog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The test bundle, not Bundle.main, which is the host app.
        catalog = try CityCatalog.load(from: Bundle(for: CityCatalogTests.self))
    }

    override func tearDownWithError() throws {
        catalog = nil
        try super.tearDownWithError()
    }

    // MARK: - The shipped catalog

    func testCatalogLoadsAndIsVersionOne() {
        XCTAssertEqual(catalog.catalogVersion, 1)
    }

    func testCatalogListsTwentyCities() {
        XCTAssertEqual(catalog.cities.count, 20)
    }

    func testCityIdsAreUniqueAndSlugShaped() {
        let ids = catalog.cities.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate city id in the catalog")

        for id in ids {
            XCTAssertFalse(id.isEmpty)
            // Ids appear in file names and URLs, so they stay lowercase
            // letters, digits and hyphens.
            XCTAssertNotNil(
                id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression),
                "\(id) is not a usable slug"
            )
        }
    }

    func testEveryPackIsStillUnbuilt() {
        for city in catalog.cities {
            XCTAssertNil(city.pack, "\(city.id) carries a pack descriptor that no build produced")
            XCTAssertFalse(city.isAvailable)
        }
        XCTAssertTrue(catalog.available.isEmpty)
        XCTAssertEqual(catalog.pending.count, 20)
    }

    func testPackBaseURLIsHTTPS() {
        XCTAssertEqual(catalog.packBaseURL.scheme, "https")
    }

    func testEveryCityHasUsableMetadata() {
        for city in catalog.cities {
            XCTAssertFalse(city.name.isEmpty, "\(city.id) has no display name")
            XCTAssertFalse(city.country.isEmpty, "\(city.id) has no country")
            XCTAssertNotNil(
                city.countryCode.range(of: "^[A-Z]{2}$", options: .regularExpression),
                "\(city.id) has a country code that is not ISO 3166-1 alpha-2: \(city.countryCode)"
            )
        }
    }

    func testEveryCityCentreIsInsideItsCameraBounds() {
        // The bounds only frame the initial map camera, but a centre outside
        // them means the map opens looking at the wrong place.
        for city in catalog.cities {
            XCTAssertTrue(
                city.cameraBounds.contains(city.center),
                "\(city.id): centre is outside its camera bounds"
            )
            XCTAssertLessThan(city.cameraBounds.minLatitude, city.cameraBounds.maxLatitude)
            XCTAssertLessThan(city.cameraBounds.minLongitude, city.cameraBounds.maxLongitude)
        }
    }

    func testPendingCitiesAreSortedByName() {
        let names = catalog.pending.map(\.name)
        XCTAssertEqual(names, names.sorted())
    }

    // MARK: - Lookup

    func testLookupById() {
        let newYork = catalog.city(id: "new-york")
        XCTAssertEqual(newYork?.name, "New York")
        XCTAssertEqual(newYork?.countryCode, "US")
        XCTAssertNil(catalog.city(id: "atlantis"))
    }

    func testLookupByCoordinate() {
        // Lower Manhattan.
        let city = catalog.city(containing: Coordinate(latitude: 40.7128, longitude: -74.0060))
        XCTAssertEqual(city?.id, "new-york")
    }

    func testLookupByCoordinateFindsNothingInTheMiddleOfNowhere() {
        // Somewhere over Antarctica.
        XCTAssertNil(catalog.city(containing: Coordinate(latitude: -80, longitude: 0)))
    }

    // MARK: - Decoding rules

    private func decode(_ json: String) throws -> CityCatalog {
        try JSONDecoder().decode(CityCatalog.self, from: Data(json.utf8))
    }

    private func catalogJSON(packBaseURL: String, pack: String = "null") -> String {
        """
        {
          "catalogVersion": 3,
          "packBaseURL": "\(packBaseURL)",
          "cities": [
            {
              "id": "testville",
              "name": "Testville",
              "country": "Testland",
              "countryCode": "TL",
              "center": { "latitude": 1.5, "longitude": 2.5 },
              "cameraBounds": {
                "minLatitude": 1.0, "minLongitude": 2.0,
                "maxLatitude": 2.0, "maxLongitude": 3.0
              },
              "pack": \(pack)
            }
          ]
        }
        """
    }

    func testHTTPSCatalogDecodes() throws {
        let decoded = try decode(catalogJSON(packBaseURL: "https://packs.example.com/v1/"))

        XCTAssertEqual(decoded.catalogVersion, 3)
        XCTAssertEqual(decoded.packBaseURL.absoluteString, "https://packs.example.com/v1/")
        XCTAssertEqual(decoded.cities.count, 1)
        XCTAssertEqual(decoded.cities[0].id, "testville")
        XCTAssertNil(decoded.cities[0].pack)
    }

    func testNonHTTPSPackBaseURLIsRejected() {
        // The digests in the catalog are only worth anything if the catalog
        // and the packs both arrive over a channel that cannot be rewritten
        // in transit.
        for insecure in [
            "http://packs.example.com/v1/",
            "ftp://packs.example.com/v1/",
            "file:///tmp/packs/",
            "packs/relative/path/"
        ] {
            XCTAssertThrowsError(
                try decode(catalogJSON(packBaseURL: insecure)),
                "\(insecure) should be rejected"
            ) { error in
                XCTAssertTrue(error is DecodingError, "threw \(error)")
            }
        }
    }

    func testUppercaseSchemeIsAccepted() throws {
        // The scheme is compared case insensitively, as URLs are.
        let decoded = try decode(catalogJSON(packBaseURL: "HTTPS://packs.example.com/v1/"))
        XCTAssertEqual(decoded.packBaseURL.scheme?.lowercased(), "https")
    }

    func testPackDescriptorDecodes() throws {
        let pack = """
        {
          "version": 2,
          "path": "testville.v2.sqlite.gz",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "compressedBytes": 1234567,
          "segmentCount": 4321,
          "totalLengthMetres": 987654.5
        }
        """
        let decoded = try decode(catalogJSON(packBaseURL: "https://packs.example.com/v1/", pack: pack))
        let city = try XCTUnwrap(decoded.cities.first)
        let descriptor = try XCTUnwrap(city.pack)

        XCTAssertTrue(city.isAvailable)
        XCTAssertEqual(descriptor.version, 2)
        XCTAssertEqual(descriptor.path, "testville.v2.sqlite.gz")
        XCTAssertEqual(descriptor.sha256.count, 64)
        XCTAssertEqual(descriptor.compressedBytes, 1_234_567)
        XCTAssertEqual(descriptor.segmentCount, 4_321)
        XCTAssertEqual(descriptor.totalLengthMetres, 987_654.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.available.count, 1)
        XCTAssertTrue(decoded.pending.isEmpty)
    }

    func testMissingRequiredFieldIsRejected() {
        let missingName = """
        {
          "catalogVersion": 1,
          "packBaseURL": "https://packs.example.com/v1/",
          "cities": [
            {
              "id": "testville",
              "country": "Testland",
              "countryCode": "TL",
              "center": { "latitude": 1.5, "longitude": 2.5 },
              "cameraBounds": {
                "minLatitude": 1.0, "minLongitude": 2.0,
                "maxLatitude": 2.0, "maxLongitude": 3.0
              },
              "pack": null
            }
          ]
        }
        """
        XCTAssertThrowsError(try decode(missingName)) { error in
            XCTAssertTrue(error is DecodingError, "threw \(error)")
        }
    }

    func testUnknownFieldsAreIgnored() throws {
        // The shipped catalog carries _note and approxRadiusKm, neither of
        // which the app reads. Adding a field must not break older builds.
        let withExtras = """
        {
          "catalogVersion": 1,
          "_note": "a comment",
          "packBaseURL": "https://packs.example.com/v1/",
          "somethingNew": { "nested": true },
          "cities": [
            {
              "id": "testville",
              "name": "Testville",
              "country": "Testland",
              "countryCode": "TL",
              "approxRadiusKm": 9,
              "center": { "latitude": 1.5, "longitude": 2.5 },
              "cameraBounds": {
                "minLatitude": 1.0, "minLongitude": 2.0,
                "maxLatitude": 2.0, "maxLongitude": 3.0
              },
              "pack": null
            }
          ]
        }
        """
        XCTAssertEqual(try decode(withExtras).cities.count, 1)
    }
}
