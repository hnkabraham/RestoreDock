import XCTest
@testable import FirmwareCore

final class FirmwareCleanupTests: XCTestCase {
    private let url = URL(string: "https://updates.cdn-apple.com/firmware/restore.ipsw")!

    func testUnsignedExactMatchWithCanonicalURLIsEligibleWithoutChecksum() async throws {
        let saved = item("download", models: ["iPhone16,1"])
        let canonicalVariant = URL(string: "https://UPDATES.CDN-APPLE.COM:443/firmware/restore.ipsw#fragment")!
        let release = FirmwareRelease(version: saved.version, build: saved.build, isSigned: false, downloadURL: canonicalVariant)
        XCTAssertNil(release.sha1)
        let fixture = HistoryFixture(histories: ["iPhone16,1": history("iPhone16,1", releases: [release])])
        let plan = try await service(fixture).evaluate([saved])
        XCTAssertEqual(plan.unsignedDownloadIDs, [saved.id])
        XCTAssertEqual(plan.checkedCount, 1)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testSharedImageIsKeptWhenAnyAssociatedModelIsStillSigned() async throws {
        let fixture = HistoryFixture(histories: [
            "iPhone16,1": history("iPhone16,1", releases: [release(signed: false)]),
            "iPhone16,2": history("iPhone16,2", releases: [release(signed: true)])
        ])
        let plan = try await service(fixture).evaluate([item("shared", models: ["iPhone16,1", "iPhone16,2"])])
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.checkedCount, 1)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertTrue(plan.signingApprovalExpirations.isEmpty)
    }

    func testApprovalExpiresFifteenMinutesAfterOldestSharedModelEvidence() async throws {
        let earliest = Date().addingTimeInterval(-7 * 60)
        let recent = earliest.addingTimeInterval(4 * 60)
        let fixture = HistoryFixture(histories: [
            "iPhone16,1": history("iPhone16,1", releases: [release(signed: false)], fetchedAt: recent),
            "iPhone16,2": history("iPhone16,2", releases: [release(signed: false)], fetchedAt: earliest)
        ])
        let plan = try await service(fixture).evaluate([item("shared", models: ["iPhone16,1", "iPhone16,2"])])
        XCTAssertEqual(plan.unsignedDownloadIDs, ["shared"])
        XCTAssertEqual(plan.signingApprovalExpirations, ["shared": earliest.addingTimeInterval(15 * 60)])
    }

    func testRequiresExactVersionBuildAndValidatedAppleURL() async throws {
        let mismatches = [
            FirmwareRelease(version: "26.0.1", build: "23A100", isSigned: false, downloadURL: url),
            FirmwareRelease(version: "26.0", build: "23A101", isSigned: false, downloadURL: url),
            FirmwareRelease(version: "26.0", build: "23A100", isSigned: false,
                downloadURL: URL(string: "https://updates.cdn-apple.com/firmware/different.ipsw")),
            FirmwareRelease(version: "26.0", build: "23A100", isSigned: false,
                downloadURL: URL(string: "http://updates.cdn-apple.com/firmware/restore.ipsw")),
            FirmwareRelease(version: "26.0", build: "23A100", isSigned: false)
        ]
        for mismatch in mismatches {
            let fixture = HistoryFixture(histories: ["iPhone16,1": history("iPhone16,1", releases: [mismatch])])
            let plan = try await service(fixture).evaluate([item("saved", models: ["iPhone16,1"])])
            XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
            XCTAssertEqual(plan.checkedCount, 0)
            XCTAssertEqual(plan.skippedCount, 1)
            XCTAssertFalse(plan.warnings.isEmpty)
        }
    }

    func testFetchFailureAndMissingRecordSkipOnlyAffectedDownloads() async throws {
        let fixture = HistoryFixture(histories: [
            "iPhone16,2": history("iPhone16,2", releases: []),
            "iPhone16,3": history("iPhone16,3", releases: [release(signed: false)])
        ], failures: ["iPhone16,1"])
        let saved = [item("failed", models: ["iPhone16,1"]), item("absent", models: ["iPhone16,2"]), item("eligible", models: ["iPhone16,3"])]
        let plan = try await service(fixture).evaluate(saved)
        XCTAssertEqual(plan.unsignedDownloadIDs, ["eligible"])
        XCTAssertEqual(plan.checkedCount, 1)
        XCTAssertEqual(plan.skippedCount, 2)
        XCTAssertGreaterThanOrEqual(plan.warnings.count, 2)
    }

    func testFetchesEachModelOnceAcrossVersionsAndRepeatedModelIdentifiers() async throws {
        let old = item("older", models: ["iPhone16,1", "iPhone16,1"])
        var new = item("newer", models: ["iPhone16,1"])
        new.version = "26.1"; new.build = "23B100"
        new.url = URL(string: "https://updates.cdn-apple.com/firmware/newer.ipsw")!
        let records = [release(signed: false), FirmwareRelease(version: new.version, build: new.build, isSigned: false, downloadURL: new.url)]
        let fixture = HistoryFixture(histories: ["iPhone16,1": history("iPhone16,1", releases: records)])
        let plan = try await service(fixture).evaluate([old, new])
        let requests = await fixture.requests()
        XCTAssertEqual(requests, ["iPhone16,1"])
        XCTAssertEqual(plan.unsignedDownloadIDs, ["older", "newer"])
        XCTAssertEqual(plan.checkedCount, 2)
    }

    func testIncompleteOrInvalidQueueEntriesNeverFetchOrBecomeEligible() async throws {
        let fixture = HistoryFixture(histories: [:])
        var pending = item("pending", models: ["iPhone16,1"]); pending.status = .downloading
        var unsafe = item("unsafe", models: ["iPhone16,1"])
        unsafe.url = URL(string: "https://apple.com.evil.example/restore.ipsw")!
        let plan = try await service(fixture).evaluate([pending, item("empty", models: []),
            item("invalid", models: ["iPhone16,1/extra"]), unsafe])
        let requests = await fixture.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.checkedCount, 0)
        XCTAssertEqual(plan.skippedCount, 3)
    }

    func testDuplicateQueueIDsAreKeptWithoutFetching() async throws {
        let fixture = HistoryFixture(histories: [:])
        let saved = item("duplicate", models: ["iPhone16,1"])
        let plan = try await service(fixture).evaluate([saved, saved])
        let requests = await fixture.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.skippedCount, 2)
    }

    func testProtectedImportsNeverFetchOrBecomeEligible() async throws {
        let fixture = HistoryFixture(histories: [:])
        var saved = item("imported", models: ["iPhone16,1"])
        saved.importedAt = Date()
        let plan = try await service(fixture).evaluate([saved])
        let requests = await fixture.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.skippedCount, 1)
        XCTAssertTrue(plan.warnings.first?.contains("protected") == true)
    }

    func testImportExplicitlyAllowedForCleanupUsesNormalSigningChecks() async throws {
        let fixture = HistoryFixture(histories: ["iPhone16,1": history("iPhone16,1", releases: [release(signed: false)])])
        var saved = item("imported", models: ["iPhone16,1"])
        saved.importedAt = Date(); saved.importedCleanupAllowed = true
        let plan = try await service(fixture).evaluate([saved])
        XCTAssertEqual(plan.unsignedDownloadIDs, ["imported"])
        XCTAssertEqual(plan.checkedCount, 1)
    }

    func testConflictingSigningAndStaleHistoryCannotAuthorizeCleanup() async throws {
        let conflict = FirmwareRelease(version: "26.0", build: "23A100", isSigned: false,
            downloadURL: url, isSigningStatusConflicting: true)
        let fixture = HistoryFixture(histories: [
            "iPhone16,1": history("iPhone16,1", releases: [conflict]),
            "iPhone16,2": history("iPhone16,2", releases: [release(signed: false)], fetchedAt: .distantPast),
            "iPhone16,3": history("iPhone16,3", releases: [release(signed: false)], fetchedAt: .distantFuture)
        ])
        let plan = try await service(fixture).evaluate([item("conflict", models: ["iPhone16,1"]),
            item("stale", models: ["iPhone16,2"]), item("future", models: ["iPhone16,3"])])
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.skippedCount, 3)
    }

    func testWrongDeviceResponseAndUnknownSharedModelKeepFile() async throws {
        let fixture = HistoryFixture(histories: [
            "iPhone16,1": history("iPhone16,1", releases: [release(signed: false)]),
            "iPhone16,2": history("iPhone16,3", releases: [release(signed: false)])
        ])
        let plan = try await service(fixture).evaluate([item("shared", models: ["iPhone16,1", "iPhone16,2"])])
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func testAnySignedReportForSameVersionBuildRetainsFile() async throws {
        let signedAlternate = FirmwareRelease(version: "26.0", build: "23A100", isSigned: true,
            downloadURL: URL(string: "https://updates.cdn-apple.com/firmware/alternate.ipsw"))
        let fixture = HistoryFixture(histories: ["iPhone16,1": history("iPhone16,1", releases: [release(signed: false), signedAlternate])])
        let plan = try await service(fixture).evaluate([item("saved", models: ["iPhone16,1"])])
        XCTAssertTrue(plan.unsignedDownloadIDs.isEmpty)
        XCTAssertEqual(plan.checkedCount, 1)
    }

    func testCancellationDuringFetchThrowsInsteadOfReturningPartialPlan() async throws {
        let probe = SuspendedHistoryFetcher(history: history("iPhone16,1", releases: [release(signed: false)]))
        let evaluator = FirmwareCleanupService { try await probe.fetch($0) }
        let saved = item("saved", models: ["iPhone16,1"])
        let task = Task { try await evaluator.evaluate([saved]) }
        await probe.waitForStart()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled evaluation must not return an actionable cleanup plan.")
        } catch is CancellationError {
            // Expected: no partial cleanup decision escapes a cancelled check.
        }
    }

    private func item(_ id: String, models: [String]) -> DownloadItem {
        DownloadItem(id: id, name: "Test Device", modelIdentifiers: models, version: "26.0",
            build: "23A100", url: url, filename: "restore.ipsw", status: .ready)
    }

    private func release(signed: Bool) -> FirmwareRelease {
        FirmwareRelease(version: "26.0", build: "23A100", isSigned: signed, downloadURL: url)
    }

    private func history(_ id: String, releases: [FirmwareRelease], fetchedAt: Date = Date()) -> FirmwareHistory {
        FirmwareHistory(deviceIdentifier: id, deviceName: "Test Device", releases: releases, fetchedAt: fetchedAt)
    }

    private func service(_ fixture: HistoryFixture) -> FirmwareCleanupService {
        FirmwareCleanupService { try await fixture.fetch($0) }
    }
}

private actor HistoryFixture {
    let histories: [String: FirmwareHistory]
    let failures: Set<String>
    private var requested: [String] = []

    init(histories: [String: FirmwareHistory], failures: Set<String> = []) {
        self.histories = histories; self.failures = failures
    }

    func fetch(_ identifier: String) throws -> FirmwareHistory {
        requested.append(identifier)
        if failures.contains(identifier) { throw URLError(.notConnectedToInternet) }
        guard let history = histories[identifier] else { throw URLError(.resourceUnavailable) }
        return history
    }

    func requests() -> [String] { requested }
}

private actor SuspendedHistoryFetcher {
    let history: FirmwareHistory
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?

    init(history: FirmwareHistory) { self.history = history }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }

    func fetch(_ identifier: String) async throws -> FirmwareHistory {
        started = true
        observer?.resume(); observer = nil
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return history
    }
}
