import XCTest
@testable import FirmwareCore

final class FirmwareHistoryTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!

    func testSortsNumericallyAndDeduplicatesBuildsDeterministically() throws {
        let records = [release("18.9", "22A9"), release("18.10", "22A10"),
                       release("27.0", "24A100", date: "2026-09-10T12:00:00Z"),
                       release("27.0", "24A101", date: "2026-09-11T12:00:00Z"),
                       release("18.10", "22A10", signed: true)]
        let history = try parse(records)
        XCTAssertEqual(history.releases.map(\.build), ["24A101", "24A100", "22A10", "22A9"])
        XCTAssertEqual(history.releases, try parse(Array(records.reversed())).releases)
        XCTAssertFalse(history.releases[2].isSigned)
        XCTAssertTrue(history.releases[2].isSigningStatusConflicting)
        XCTAssertFalse(history.releases[0].isSigningStatusConflicting)
        XCTAssertEqual(history.fetchedAt, now)
    }

    func testRetainsDateSizeAndSigningMetadataWithoutDownloadURLs() throws {
        var missing = release("17.0", "21A100")
        missing["releasedate"] = NSNull(); missing["filesize"] = 0
        let history = try parse([missing, release("18.0", "22A100", date: "2024-09-16T17:00:00.123Z", signed: true)])
        XCTAssertEqual(history.deviceIdentifier, "iPhone16,1")
        XCTAssertEqual(history.deviceName, "iPhone 15 Pro")
        XCTAssertEqual(history.releases[0].fileSize, 12_000_000_000)
        XCTAssertNotNil(history.releases[0].releaseDate)
        XCTAssertTrue(history.releases[0].isSigned)
        XCTAssertNil(history.releases[1].releaseDate)
        XCTAssertNil(history.releases[1].fileSize)
    }

    func testExcludesExplicitPrereleasesOtherModelsAndFutureReleases() throws {
        var flagged = release("28.0", "25A100"); flagged["beta"] = true
        var other = release("27.1", "24B100"); other["identifier"] = "iPhone16,2"
        let history = try parse([release("27.0.1", "24A101"), release("28.0 beta 1", "25A100a"),
                                 release("28.0 RC", "25A100b"), flagged, other,
                                 release("28.0", "25A200", date: "2027-09-01T00:00:00Z")])
        XCTAssertEqual(history.releases.map(\.version), ["27.0.1"])
    }

    func testRejectsWrongDeviceAndInvalidMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": "Wrong phone", "identifier": "iPhone16,2", "firmwares": []])
        XCTAssertThrowsError(try FirmwareHistoryService.parse(data: data, deviceIdentifier: "iPhone16,1", now: now))
        XCTAssertThrowsError(try FirmwareHistoryService.parse(data: Data("{}".utf8), deviceIdentifier: "iPhone16,1", now: now))
        XCTAssertThrowsError(try parse([]))
        for identifier in ["iPhone16,1/other", "../iPhone16,1", "Mac14,2", "iPhone16,1?type=ota", "iPhone16,1\n"] {
            XCTAssertThrowsError(try FirmwareHistoryService.parse(data: data, deviceIdentifier: identifier, now: now))
        }
    }

    func testUnknownDatesStayUnknownAndEmptyNameUsesIdentifier() throws {
        let history = try parse([release("18.0", "22A100", date: "unknown")], name: "   ")
        XCTAssertNil(history.releases[0].releaseDate)
        XCTAssertEqual(history.deviceName, history.deviceIdentifier)
    }

    func testSignedAppleIPSWMetadataConvertsToQueueInput() throws {
        var record = release("18.7", "22H100", signed: true)
        record["url"] = "https://updates.cdn-apple.com/firmware/older_restore.ipsw"
        record["sha1sum"] = "  " + String(repeating: "A1", count: 20) + "\n"
        let history = try parse([record])
        let item = try XCTUnwrap(history.releases.first)
        XCTAssertTrue(item.canDownload)
        XCTAssertFalse(item.isSigningStatusConflicting)
        XCTAssertEqual(item.sha1, String(repeating: "a1", count: 20))
        let firmware = try XCTUnwrap(item.firmware(deviceIdentifier: history.deviceIdentifier, name: history.deviceName))
        XCTAssertEqual(firmware.id, history.deviceIdentifier)
        XCTAssertEqual(firmware.name, history.deviceName)
        XCTAssertEqual(firmware.version, "18.7")
        XCTAssertEqual(firmware.build, "22H100")
        XCTAssertEqual(firmware.downloadURL, item.downloadURL)
        XCTAssertEqual(firmware.sha1, item.sha1)
        XCTAssertEqual(firmware.fileSize, item.fileSize)
        XCTAssertEqual(firmware.releaseDate, item.releaseDate)
    }

    func testUnsignedMissingOrUnsafeMetadataCannotBecomeDownload() {
        let goodURL = URL(string: "https://updates.cdn-apple.com/firmware/restore.ipsw")!
        let checksum = String(repeating: "ab", count: 20)
        let unsigned = FirmwareRelease(version: "18.7", build: "22H100", isSigned: false, downloadURL: goodURL, sha1: checksum)
        XCTAssertFalse(unsigned.canDownload)
        XCTAssertNil(unsigned.firmware(deviceIdentifier: "iPhone16,1", name: "Phone"))
        for rawURL in ["http://updates.cdn-apple.com/restore.ipsw", "https://apple.com.evil.example/restore.ipsw",
                       "https://updates.cdn-apple.com/restore.zip", "https://user:secret@updates.cdn-apple.com/restore.ipsw",
                       "https://updates.cdn-apple.com:444/restore.ipsw"] {
            let item = FirmwareRelease(version: "18.7", build: "22H100", isSigned: true, downloadURL: URL(string: rawURL), sha1: checksum)
            XCTAssertNil(item.downloadURL)
            XCTAssertFalse(item.canDownload)
            XCTAssertNil(item.firmware(deviceIdentifier: "iPhone16,1", name: "Phone"))
        }
        for badChecksum in [nil, "", "not-a-checksum", String(repeating: "z", count: 40), String(repeating: "a", count: 39)] as [String?] {
            let item = FirmwareRelease(version: "18.7", build: "22H100", isSigned: true, downloadURL: goodURL, sha1: badChecksum)
            XCTAssertNil(item.sha1)
            XCTAssertFalse(item.canDownload)
        }
        XCTAssertFalse(FirmwareRelease(version: "18.7", build: "22H100", isSigned: true, sha1: checksum).canDownload)
        let valid = FirmwareRelease(version: "18.7", build: "22H100", isSigned: true, downloadURL: goodURL, sha1: checksum)
        XCTAssertNil(valid.firmware(deviceIdentifier: "iPhone16,1/other", name: "Phone"))
    }

    func testBrokenDownloadMetadataDoesNotHideHistoryEntries() throws {
        var unsafe = release("18.7", "22H100", signed: true)
        unsafe["url"] = "https://example.com/restore.ipsw"
        unsafe["sha1sum"] = String(repeating: "a", count: 40)
        var malformed = release("18.6", "22G100", signed: true)
        malformed["url"] = 123
        malformed["sha1sum"] = ["unexpected": "object"]
        var badChecksum = release("18.5", "22F100", signed: true)
        badChecksum["url"] = "https://updates.cdn-apple.com/restore.ipsw"
        badChecksum["sha1sum"] = "invalid"
        let history = try parse([unsafe, malformed, badChecksum])
        XCTAssertEqual(history.releases.count, 3)
        XCTAssertTrue(history.releases.allSatisfy(\.isSigned))
        XCTAssertTrue(history.releases.allSatisfy { !$0.canDownload })
        XCTAssertNil(history.releases[0].downloadURL)
        XCTAssertNil(history.releases[1].sha1)
    }

    func testDuplicateSignedRecordsPreferUsableMetadataDeterministically() throws {
        let missing = release("18.7", "22H100", signed: true)
        var usable = missing
        usable["url"] = "https://updates.cdn-apple.com/restore.ipsw"
        usable["sha1sum"] = String(repeating: "a", count: 40)
        let first = try parse([missing, usable]).releases
        let reversed = try parse([usable, missing]).releases
        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].canDownload)
        XCTAssertFalse(first[0].isSigningStatusConflicting)
    }

    func testConflictingSigningRecordsCannotBecomeDownloadsInEitherOrder() throws {
        var signed = release("18.7", "22H100", signed: true)
        signed["url"] = "https://updates.cdn-apple.com/restore.ipsw"
        signed["sha1sum"] = String(repeating: "a", count: 40)
        var unsigned = signed
        unsigned["signed"] = false

        let forward = try parse([signed, unsigned]).releases
        let reverse = try parse([unsigned, signed]).releases
        XCTAssertEqual(forward, reverse)
        let item = try XCTUnwrap(forward.first)
        XCTAssertEqual(forward.count, 1)
        XCTAssertTrue(item.isSigningStatusConflicting)
        XCTAssertFalse(item.canDownload)
        XCTAssertNil(item.firmware(deviceIdentifier: "iPhone16,1", name: "Phone"))
    }

    func testSigningConflictSurvivesDifferentVersionDateAndDownloadMetadata() throws {
        var signed = release("18.7", "22H100", date: "2025-09-15T00:00:00Z", signed: true)
        signed["url"] = "https://updates.cdn-apple.com/restore.ipsw"
        signed["sha1sum"] = String(repeating: "a", count: 40)
        // The signed row wins ordinary version/date sorting. The conflicting
        // row still blocks both downloads and a consumer's unsigned cleanup.
        let unsigned = release("18.6", "22H100", date: "2024-01-01T00:00:00Z")
        let forward = try parse([signed, unsigned]).releases
        XCTAssertEqual(forward, try parse([unsigned, signed]).releases)
        let item = try XCTUnwrap(forward.first)
        XCTAssertTrue(item.isSigned)
        XCTAssertTrue(item.isSigningStatusConflicting)
        XCTAssertFalse(item.canDownload)
        XCTAssertNil(item.firmware(deviceIdentifier: "iPhone16,1", name: "Phone"))
    }

    func testFilteredDuplicateSigningEvidenceBlocksCleanupButOtherModelsDoNot() throws {
        let unsigned = release("18.7", "22H100")
        let future = release("28.0", "22H100", date: "2027-09-01T00:00:00Z", signed: true)
        var beta = release("28.0 beta", "22H100", signed: true)
        beta["beta"] = true
        for conflicting in [future, beta] {
            let forward = try parse([unsigned, conflicting]).releases
            XCTAssertEqual(forward, try parse([conflicting, unsigned]).releases)
            XCTAssertEqual(forward.count, 1)
            XCTAssertEqual(forward[0].version, "18.7")
            XCTAssertFalse(forward[0].isSigned)
            XCTAssertTrue(forward[0].isSigningStatusConflicting)
        }
        var otherModel = release("18.7", "22H100", signed: true)
        otherModel["identifier"] = "iPhone16,2"
        XCTAssertFalse(try parse([unsigned, otherModel]).releases[0].isSigningStatusConflicting)
    }

    func testExplicitSigningConflictDisablesOtherwiseValidMetadata() {
        let item = FirmwareRelease(version: "18.7", build: "22H100", isSigned: true,
            downloadURL: URL(string: "https://updates.cdn-apple.com/restore.ipsw"),
            sha1: String(repeating: "a", count: 40), isSigningStatusConflicting: true)
        XCTAssertTrue(item.isSigningStatusConflicting)
        XCTAssertFalse(item.canDownload)
        XCTAssertNil(item.firmware(deviceIdentifier: "iPhone16,1", name: "Phone"))
    }

    func testAppleNotesUseVerifiedFamilySpecificArticles() {
        XCTAssertEqual(AppleReleaseNotes.url(deviceIdentifier: "iPhone16,1", version: "27.0.1").path, "/en-us/149076")
        XCTAssertEqual(AppleReleaseNotes.url(deviceIdentifier: "iPad16,3", version: "27.0.1").path, "/en-us/149075")
        XCTAssertEqual(AppleReleaseNotes.url(deviceIdentifier: "iPhone16,1", version: "18.7").path, "/en-us/121161")
        XCTAssertEqual(AppleReleaseNotes.url(deviceIdentifier: "iPad16,3", version: "18.7").path, "/en-us/121162")
        XCTAssertTrue(AppleReleaseNotes.isDirectArticle(deviceIdentifier: "iPad16,3", version: "26.0"))
    }

    func testAppleSearchFallbackHandlesUnknownVersionsAndPreIPadOSNames() {
        let old = AppleReleaseNotes.url(deviceIdentifier: "iPad4,1", version: "12.5.7")
        let future = AppleReleaseNotes.url(deviceIdentifier: "iPad16,3", version: "99.0")
        XCTAssertEqual(old.host, "support.apple.com")
        XCTAssertEqual(old.path, "/kb/index")
        XCTAssertEqual(URLComponents(url: old, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "iOS 12.5.7 updates")
        XCTAssertEqual(URLComponents(url: future, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "iPadOS 99.0 updates")
        XCTAssertFalse(AppleReleaseNotes.isDirectArticle(deviceIdentifier: "iPad16,3", version: "99.0"))
    }

    private func release(_ version: String, _ build: String, date: String = "2024-01-01T00:00:00Z", signed: Bool = false) -> [String: Any] {
        ["identifier": "iPhone16,1", "version": version, "buildid": build,
         "releasedate": date, "filesize": 12_000_000_000 as Int64, "signed": signed]
    }

    private func parse(_ records: [[String: Any]], name: String = "iPhone 15 Pro") throws -> FirmwareHistory {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "identifier": "iPhone16,1", "firmwares": records])
        return try FirmwareHistoryService.parse(data: data, deviceIdentifier: "iPhone16,1", now: now)
    }
}
