import XCTest
@testable import FirmwareCore

final class FirmwareStorageTests: XCTestCase {
    func testSharedModelsOverlapButVersionAndTotalCountFileOnlyOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeFile(directory, name: "shared.ipsw", bytes: 32)
        let saved = item("shared", file: file, bytes: 32, models: ["iPhone16,1", "iPhone16,2", "iPhone16,1"])
        let snapshot = try await FirmwareStorageService().snapshot([saved])
        XCTAssertEqual(snapshot.totalByteCount, 32)
        XCTAssertEqual(snapshot.presentFileCount, 1)
        XCTAssertEqual(snapshot.readyFileCount, 1)
        XCTAssertEqual(snapshot.modelGroups.count, 2)
        XCTAssertTrue(snapshot.modelGroups.allSatisfy { $0.byteCount == 32 && $0.fileCount == 1 && $0.sharedFileCount == 1 })
        XCTAssertEqual(snapshot.versionGroups.count, 1)
        XCTAssertEqual(snapshot.versionGroups.first?.byteCount, 32)
    }

    func testDuplicatePathsAndHardLinksAreOnePhysicalFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeFile(directory, name: "original.ipsw", bytes: 64)
        let hardLink = directory.appendingPathComponent("hardlink.ipsw")
        try FileManager.default.linkItem(at: first, to: hardLink)
        let saved = [item("original", file: first, bytes: 64, models: ["iPhone16,1"]),
                     item("duplicate", file: first, bytes: 64, models: ["iPhone16,1"]),
                     item("hardlink", file: hardLink, bytes: 64, models: ["iPhone16,2"])]
        let snapshot = try await FirmwareStorageService().snapshot(saved)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.presentFileCount, 1)
        XCTAssertEqual(snapshot.totalByteCount, 64)
        XCTAssertEqual(Set(snapshot.entries.compactMap(\.physicalFileID)).count, 1)
        XCTAssertEqual(snapshot.modelGroups.map(\.byteCount), [64, 64])
        XCTAssertEqual(snapshot.versionGroups.map(\.byteCount), [64])
    }

    func testMissingUnavailableAndChangedFilesUseActualSizesOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = try writeFile(directory, name: "changed.ipsw", bytes: 19)
        var absent = item("missing", file: directory.appendingPathComponent("missing.ipsw"), bytes: 9_000_000)
        // Missing completed entries become failed when the queue is restored.
        absent.status = .failed
        let unavailable = item("directory", file: directory, bytes: 8_000_000)
        var queued = item("queued", file: changed, bytes: 19)
        queued.status = .queued
        let snapshot = try await FirmwareStorageService().snapshot([
            absent, unavailable, item("changed", file: changed, bytes: 27), queued
        ])
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.missingCount, 1)
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.changedCount, 1)
        XCTAssertEqual(snapshot.totalByteCount, 19)
        XCTAssertEqual(snapshot.readyFileCount, 0)
        XCTAssertEqual(snapshot.presentFileCount, 1)
        XCTAssertNil(snapshot.entries.first { $0.item.name == "missing" }?.actualByteCount)
        XCTAssertEqual(snapshot.entries.first { $0.item.name == "changed" }?.actualByteCount, 19)
    }

    func testConflictingVersionMetadataDoesNotDoubleCountAliases() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeFile(directory, name: "shared.ipsw", bytes: 20)
        let first = item("one", file: file, bytes: 20)
        var second = item("two", file: file, bytes: 20)
        second.version = "26.1"; second.build = "23B100"
        let snapshot = try await FirmwareStorageService().snapshot([first, second])
        XCTAssertEqual(snapshot.totalByteCount, 20)
        XCTAssertEqual(snapshot.versionGroups.count, 1)
        XCTAssertEqual(snapshot.versionGroups.first?.label, "Conflicting saved versions")
        XCTAssertEqual(snapshot.versionGroups.first?.byteCount, 20)
    }

    func testPreviewRequiresCurrentSigningEvidenceAndUnchangedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try writeFile(directory, name: "valid.ipsw", bytes: 20)
        let changed = try writeFile(directory, name: "changed.ipsw", bytes: 10)
        let expired = try writeFile(directory, name: "expired.ipsw", bytes: 30)
        let validItem = item("valid", file: valid, bytes: 20)
        let changedItem = item("changed", file: changed, bytes: 20)
        let expiredItem = item("expired", file: expired, bytes: 30)
        let snapshot = try await FirmwareStorageService().snapshot([validItem, changedItem, expiredItem])
        let expiry = Date().addingTimeInterval(600)
        let plan = FirmwareCleanupPlan(unsignedDownloadIDs: [validItem.id, changedItem.id, expiredItem.id],
            checkedCount: 3, skippedCount: 1, warnings: ["A model could not be checked."],
            signingApprovalExpirations: [validItem.id: expiry, changedItem.id: expiry, expiredItem.id: .distantPast])
        let preview = snapshot.cleanupPreview(for: plan)
        XCTAssertEqual(preview.candidates.map(\.id), [validItem.id])
        XCTAssertEqual(preview.totalByteCount, 20)
        XCTAssertEqual(preview.expiresAt, expiry)
        XCTAssertEqual(preview.checkedCount, 3)
        XCTAssertEqual(preview.skippedCount, 3)
        XCTAssertEqual(preview.warnings.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
    }

    func testPreviewKeepsHardLinksWithMultipleTrackedEntriesEvenWhenAllAreUnsigned() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeFile(directory, name: "one.ipsw", bytes: 32)
        let second = directory.appendingPathComponent("two.ipsw")
        try FileManager.default.linkItem(at: first, to: second)
        let firstItem = item("one", file: first, bytes: 32)
        let secondItem = item("two", file: second, bytes: 32)
        let snapshot = try await FirmwareStorageService().snapshot([firstItem, secondItem])
        let expiry = Date().addingTimeInterval(600)
        let allUnsigned = FirmwareCleanupPlan(unsignedDownloadIDs: [firstItem.id, secondItem.id], checkedCount: 2, skippedCount: 0,
            signingApprovalExpirations: [firstItem.id: expiry, secondItem.id: expiry])
        XCTAssertTrue(snapshot.cleanupPreview(for: allUnsigned).candidates.isEmpty)
        XCTAssertEqual(snapshot.cleanupPreview(for: allUnsigned).totalByteCount, 0)
        XCTAssertEqual(snapshot.cleanupPreview(for: allUnsigned).skippedCount, 2)
        XCTAssertTrue(snapshot.cleanupPreview(for: allUnsigned).warnings.allSatisfy { $0.contains("multiple tracked entries") })
        let oneUnsigned = FirmwareCleanupPlan(unsignedDownloadIDs: [firstItem.id], checkedCount: 2, skippedCount: 0,
            signingApprovalExpirations: [firstItem.id: expiry])
        XCTAssertTrue(snapshot.cleanupPreview(for: oneUnsigned).candidates.isEmpty)
        XCTAssertEqual(snapshot.cleanupPreview(for: oneUnsigned).totalByteCount, 0)
    }

    func testImportedFilesAreCountedAndProtectedFromPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeFile(directory, name: "imported.ipsw", bytes: 32)
        var imported = item("imported", file: file, bytes: 32)
        imported.importedAt = Date()
        let snapshot = try await FirmwareStorageService().snapshot([imported])
        XCTAssertEqual(snapshot.importedCount, 1)
        XCTAssertEqual(snapshot.totalByteCount, 32)
        let plan = FirmwareCleanupPlan(unsignedDownloadIDs: [imported.id], checkedCount: 1, skippedCount: 0,
            signingApprovalExpirations: [imported.id: Date().addingTimeInterval(600)])
        let preview = snapshot.cleanupPreview(for: plan)
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertEqual(preview.skippedCount, 1)
        XCTAssertTrue(preview.warnings.first?.contains("protected") == true)
    }

    func testSymbolicLinkIsMeasuredOnceButNeverOfferedForCleanup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try writeFile(directory, name: "real.ipsw", bytes: 32)
        let link = directory.appendingPathComponent("linked.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let saved = item("link", file: link, bytes: 32)
        let snapshot = try await FirmwareStorageService().snapshot([saved])
        XCTAssertEqual(snapshot.totalByteCount, 32)
        XCTAssertEqual(snapshot.entries.first?.isSymbolicLink, true)
        let plan = FirmwareCleanupPlan(unsignedDownloadIDs: [saved.id], checkedCount: 1, skippedCount: 0,
            signingApprovalExpirations: [saved.id: Date().addingTimeInterval(600)])
        XCTAssertTrue(snapshot.cleanupPreview(for: plan).candidates.isEmpty)
    }

    func testPreviewRejectsMalformedCompletionChecksumAndDestinationRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ["completion", "checksum", "destination"].map {
            try writeFile(directory, name: "\($0).ipsw", bytes: 32)
        }
        var noCompletion = item("completion", file: files[0], bytes: 32)
        noCompletion.completedAt = nil
        var noChecksum = item("checksum", file: files[1], bytes: 32)
        noChecksum.sha1 = nil
        var wrongDestination = item("destination", file: files[2], bytes: 32)
        wrongDestination.destinationPath = directory.appendingPathComponent("elsewhere").path
        let saved = [noCompletion, noChecksum, wrongDestination]
        let snapshot = try await FirmwareStorageService().snapshot(saved)
        XCTAssertEqual(snapshot.readyFileCount, 3, "The regular files exist and their sizes match, but their queue metadata is invalid for cleanup.")
        let expiry = Date().addingTimeInterval(600)
        let plan = FirmwareCleanupPlan(unsignedDownloadIDs: saved.map(\.id), checkedCount: 3, skippedCount: 0,
            signingApprovalExpirations: Dictionary(uniqueKeysWithValues: saved.map { ($0.id, expiry) }))
        let preview = snapshot.cleanupPreview(for: plan)
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertEqual(preview.totalByteCount, 0)
        XCTAssertEqual(preview.skippedCount, 3)
        XCTAssertTrue(preview.warnings.allSatisfy { $0.contains("managed IPSW") })
    }

    func testCancelledSnapshotDoesNotReturnPartialResults() async throws {
        let gate = StorageStartGate()
        let task = Task {
            await gate.wait()
            return try await FirmwareStorageService().snapshot([])
        }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a partially measured storage snapshot.")
        } catch is CancellationError { }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirmwareStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeFile(_ directory: URL, name: String, bytes: Int) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(repeating: 0x5A, count: bytes).write(to: file)
        return file
    }

    private func item(_ id: String, file: URL, bytes: Int64, models: [String] = ["iPhone16,1"]) -> DownloadItem {
        let url = URL(string: "https://updates.cdn-apple.com/firmware/\(id)/\(file.lastPathComponent)")!
        return DownloadItem(id: DownloadManager.identifier(for: url), name: id, modelIdentifiers: models, version: "26.0", build: "23A100",
            url: url, filename: file.lastPathComponent,
            expectedBytes: bytes, downloadedBytes: bytes, status: .ready, completedAt: Date(), sha1: String(repeating: "a", count: 40),
            destinationPath: file.deletingLastPathComponent().path, localPath: file.path)
    }
}

private actor StorageStartGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}
