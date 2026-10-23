import Foundation
import XCTest
@testable import FirmwareCore

final class CatalogTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
    private let checksum = String(repeating: "ab", count: 20)
    private let imageURL = "https://updates.cdn-apple.com/public/Test_Restore.ipsw"

    func testSelectsNewestNumericPublicVersionAndIgnoresNonpublicBuild() throws {
        let candidate = "iPhone100,1"
        let snapshot = try parse(
            restores: [candidate: [restore("9.10", "A1"), restore("10.2", "B1"), restore("11.0", "BETA1")]],
            releases: [release("9.10", "A1", devices: [candidate]), release("10.2", "B1", devices: [candidate])],
            otherAssets: [release("11.0", "BETA1", devices: [candidate])],
            names: [["identifier": candidate, "name": "iPhone Test"]])

        let device = try XCTUnwrap(snapshot.devices.first)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(device.name, "iPhone Test")
        XCTAssertEqual(device.version, "10.2")
        XCTAssertEqual(device.build, "B1")
        XCTAssertEqual(device.sha1, checksum)
        XCTAssertEqual(device.fileSize, 1_000)
        XCTAssertEqual(device.releaseDate, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testDiscoversNewHardwareAndPreservesModelsSharingAnImage() throws {
        let phone = "iPhone999,1"
        let tablet = "iPad999,2"
        let snapshot = try parse(
            restores: [phone: [restore()], tablet: [restore()]],
            releases: [release(devices: [phone, tablet])])

        XCTAssertEqual(Set(snapshot.devices.map(\.id)), [phone, tablet])
        XCTAssertEqual(Set(snapshot.devices.map(\.downloadURL)).count, 1)
    }

    func testIgnoresExpiredFutureSupplementalAndOtherDeviceFamilies() throws {
        let current = "iPad100,1"
        let expired = "iPhone100,2"
        let future = "iPhone100,3"
        let supplemental = "iPhone100,4"
        let television = "AppleTV100,1"
        var supplementalRelease = release(devices: [supplemental])
        supplementalRelease["ProductVersionExtra"] = "(a)"
        let snapshot = try parse(
            restores: [current: [restore()], expired: [restore()], future: [restore()],
                       supplemental: [restore()], television: [restore()]],
            releases: [release(devices: [current]),
                       release(devices: [expired], expires: "2026-10-21"),
                       release(devices: [future], posted: "2026-10-23"),
                       supplementalRelease,
                       release(devices: [television])])

        XCTAssertEqual(snapshot.devices.map(\.id), [current])
    }

    func testModelNamesAreOptionalAndNeverControlFirmwareMetadata() throws {
        let candidate = "iPhone100,1"
        let snapshot = try parse(restores: [candidate: [restore()]],
                                 releases: [release(devices: [candidate])], names: nil)
        let device = try XCTUnwrap(snapshot.devices.first)
        XCTAssertEqual(device.name, candidate)
        XCTAssertEqual(device.downloadURL.absoluteString, imageURL)
        XCTAssertEqual(device.sha1, checksum)
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("Model names") })
    }

    func testWarnsWhenNewerPublicReleaseHasNoRestoreImageYet() throws {
        let candidate = "iPhone100,1"
        let snapshot = try parse(restores: [candidate: [restore("10.1", "A1")]],
                                 releases: [release("10.1", "A1", devices: [candidate]),
                                            release("10.2", "A2", devices: [candidate])])
        XCTAssertEqual(snapshot.devices.first?.version, "10.1")
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("catching up") })
    }

    func testUnsafeOrNonIPSWRestoreIsOmittedWithWarning() throws {
        let safe = "iPad100,1"
        let insecure = "iPhone100,2"
        let unrelatedHost = "iPhone100,3"
        let ota = "iPhone100,4"
        let snapshot = try parse(
            restores: [safe: [restore()],
                       insecure: [restore(url: "http://updates.cdn-apple.com/Test.ipsw")],
                       unrelatedHost: [restore(url: "https://updates.cdn-apple.com.attacker.test/Test.ipsw")],
                       ota: [restore(url: "https://updates.cdn-apple.com/Test.zip")]],
            releases: [release(devices: [safe, insecure, unrelatedHost, ota])])

        XCTAssertEqual(snapshot.devices.map(\.id), [safe])
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("3 supported model(s)") })
    }

    func testNoMatchingPublicBuildFailsInsteadOfReturningNonpublicImage() throws {
        XCTAssertThrowsError(try parse(restores: ["iPhone100,1": [restore("10.2", "OTHER")]],
                                       releases: [release(devices: ["iPhone100,1"])])) { error in
            guard case CatalogError.noMatchingRestoreImages = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEmptyPublicCatalogFails() throws {
        XCTAssertThrowsError(try parse(restores: [:], releases: [])) { error in
            guard case CatalogError.noPublicDevices = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMalformedChecksumDoesNotBecomeAFalseIntegrityExpectation() throws {
        var record = restore()
        record["FirmwareSHA1"] = "not a checksum"
        let snapshot = try parse(restores: ["iPhone100,1": [record]],
                                 releases: [release(devices: ["iPhone100,1"])])
        XCTAssertNil(snapshot.devices.first?.sha1)
    }

    func testAppleDownloadPolicyRejectsDomainSpoofingAndUnsafeTransports() throws {
        let accepted = ["https://updates.cdn-apple.com/file.ipsw", "https://appldnld.apple.com/file.ipsw",
                        "https://apple.com/file.ipsw", "https://cdn-apple.com/file.ipsw",
                        "https://updates.cdn-apple.com:443/file.ipsw"]
        let rejected = ["http://updates.cdn-apple.com/file.ipsw", "file:///tmp/file.ipsw",
                        "https://evilapple.com/file.ipsw", "https://evilcdn-apple.com/file.ipsw",
                        "https://apple.com.attacker.test/file.ipsw", "https://cdn-apple.com.attacker.test/file.ipsw",
                        "https://apple.com@attacker.test/file.ipsw", "https://user:secret@apple.com/file.ipsw",
                        "https://updates.cdn-apple.com:444/file.ipsw", "https://127.0.0.1/file.ipsw"]
        for raw in accepted {
            XCTAssertTrue(AppleDownloadPolicy.permits(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in rejected {
            XCTAssertFalse(AppleDownloadPolicy.permits(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    /// Opt in explicitly. This fetches catalog metadata only, never an IPSW file.
    func testLiveAppleCatalogMetadata() async throws {
        guard ProcessInfo.processInfo.environment["RESTOREDOCK_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set RESTOREDOCK_LIVE_TEST=1 to check live Apple metadata.")
        }
        let snapshot = try await CatalogService().fetch()
        XCTAssertFalse(snapshot.devices.isEmpty)
        XCTAssertEqual(Set(snapshot.devices.map(\.id)).count, snapshot.devices.count)
        XCTAssertTrue(snapshot.sourceDescription.contains("Apple"))
        for device in snapshot.devices {
            XCTAssertTrue(device.id.hasPrefix("iPhone") || device.id.hasPrefix("iPad"), device.id)
            XCTAssertFalse(device.name.isEmpty, device.id)
            XCTAssertFalse(device.version.isEmpty, device.id)
            XCTAssertFalse(device.build.isEmpty, device.id)
            XCTAssertTrue(AppleDownloadPolicy.permits(device.downloadURL), device.downloadURL.absoluteString)
            XCTAssertEqual(device.downloadURL.pathExtension.lowercased(), "ipsw")
            let digest = try XCTUnwrap(device.sha1, "Apple checksum missing for \(device.id)")
            XCTAssertEqual(digest.count, 40, device.id)
            XCTAssertTrue(digest.allSatisfy(\.isHexDigit), device.id)
        }
        print("Live Apple metadata: \(snapshot.devices.count) models, \(Set(snapshot.devices.map(\.downloadURL)).count) unique IPSWs; no firmware files downloaded.")
    }

    private func restore(_ version: String = "10.2", _ build: String = "B1",
                         url: String? = nil) -> [String: Any] {
        ["ProductVersion": version, "BuildVersion": build, "FirmwareURL": url ?? imageURL,
         "FirmwareSHA1": checksum, "FirmwareSize": 1_000]
    }

    private func release(_ version: String = "10.2", _ build: String = "B1", devices: [String],
                         posted: String = "2026-01-01", expires: String = "2027-01-01") -> [String: Any] {
        ["ProductVersion": version, "Build": build, "PostingDate": posted,
         "ExpirationDate": expires, "SupportedDevices": devices]
    }

    private func parse(restores: [String: [[String: Any]]], releases: [[String: Any]],
                       otherAssets: [[String: Any]] = [], names: [[String: String]]? = []) throws -> CatalogSnapshot {
        var modelEntries: [String: Any] = [:]
        for (identifier, records) in restores {
            var buildEntries: [String: Any] = [:]
            for (index, record) in records.enumerated() {
                buildEntries[String(index)] = ["Universal": ["Restore": record]]
            }
            modelEntries[identifier] = buildEntries
        }
        let plist: [String: Any] = ["MobileDeviceSoftwareVersionsByVersion": [
            "17": ["MobileDeviceSoftwareVersions": modelEntries]
        ]]
        let publicDocument: [String: Any] = ["PublicAssetSets": ["iOS": releases],
                                             "AssetSets": ["iOS": otherAssets]]
        return try CatalogService.parse(
            restoreCatalog: PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
            publicReleases: JSONSerialization.data(withJSONObject: publicDocument),
            deviceNames: names.map { try JSONSerialization.data(withJSONObject: $0) }, now: now)
    }
}
