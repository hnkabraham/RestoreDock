import XCTest
import CryptoKit
@testable import FirmwareCore

final class DownloadTests: XCTestCase {
    private struct SnapshotFixture: Encodable {
        var version = 1
        var items: [DownloadItem]
        var isPaused = true
        var destinationDirectory: URL
        var reserveBytes: Int64 = 0
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RestoreDockTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func firmware(_ id: String, url: String = "https://updates.cdn-apple.com/firmware/shared.ipsw") -> DeviceFirmware {
        DeviceFirmware(id: id, name: "Test Device", version: "26.0", build: "23A100", downloadURL: URL(string: url)!)
    }

    private func completedFirmware(in directory: URL, filename: String? = nil) throws -> DownloadItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = firmware("iPhone15,2")
        let id = DownloadManager.identifier(for: image.downloadURL)
        let filename = filename ?? image.downloadURL.lastPathComponent
        let file = directory.appendingPathComponent(filename)
        let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("completed firmware fixture".utf8)
        try bytes.write(to: file)
        let checksum = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return DownloadItem(id: id, name: image.name, modelIdentifiers: [image.id], version: image.version,
            build: image.build, url: image.downloadURL, filename: filename, expectedBytes: Int64(bytes.count),
            downloadedBytes: Int64(bytes.count), status: .ready, completedAt: Date(), sha1: checksum,
            destinationPath: directory.path, localPath: file.path)
    }

    @MainActor
    private func completedQueue(_ items: [DownloadItem], state: URL, destination: URL) throws -> DownloadManager {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SnapshotFixture(items: items, destinationDirectory: destination))
            .write(to: state.appendingPathComponent("downloads.json"))
        return DownloadManager(stateDirectory: state, destinationDirectory: destination)
    }

    func testCanonicalIdentifierIgnoresHostCaseDefaultPortAndFragment() {
        let first = URL(string: "https://updates.cdn-apple.com/firmware/file.ipsw")!
        let second = URL(string: "https://UPDATES.CDN-APPLE.COM:443/firmware/file.ipsw#ignored")!
        XCTAssertEqual(DownloadManager.identifier(for: first), DownloadManager.identifier(for: second))
        XCTAssertNotEqual(DownloadManager.identifier(for: first), DownloadManager.identifier(for: URL(string: "https://updates.cdn-apple.com/firmware/other.ipsw")!))
    }

    @MainActor
    func testSharedFirmwareDeduplicatesAndPersistsSelectedModels() throws {
        let folder = try temporaryFolder()
        let destination = folder.appendingPathComponent("Library")
        let manager = DownloadManager(stateDirectory: folder.appendingPathComponent("State"), destinationDirectory: destination)
        manager.pause()
        manager.enqueue([firmware("iPhone15,2"), firmware("iPhone15,3"), firmware("iPhone15,2")])
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items[0].modelIdentifiers, ["iPhone15,2", "iPhone15,3"])
        XCTAssertEqual(manager.items[0].status, .paused)
        manager.shutdown()

        let restored = DownloadManager(stateDirectory: folder.appendingPathComponent("State"), destinationDirectory: folder.appendingPathComponent("Ignored"))
        XCTAssertEqual(restored.items, manager.items)
        XCTAssertEqual(restored.destinationDirectory, destination)
        XCTAssertTrue(restored.isPaused)
        restored.shutdown()
    }

    @MainActor
    func testSignedHistoricalAndLatestFirmwareCoexistInPersistedPausedQueue() throws {
        let folder = try temporaryFolder()
        let state = folder.appendingPathComponent("State", isDirectory: true)
        let destination = folder.appendingPathComponent("Library", isDirectory: true)
        let deviceID = "iPhone16,1"
        let deviceName = "iPhone 15 Pro"
        let olderChecksum = String(repeating: "a", count: 40)
        let latestChecksum = String(repeating: "b", count: 40)
        let document: [String: Any] = [
            "identifier": deviceID, "name": deviceName,
            "firmwares": [[
                "identifier": deviceID, "version": "26.0", "buildid": "23A100",
                "releasedate": "2025-09-15T17:00:00Z", "signed": true,
                "url": "https://updates.cdn-apple.com/firmware/iPhone16_1_26.0_23A100_Restore.ipsw",
                "sha1sum": olderChecksum, "filesize": Int64(9_123_456_789)
            ]]
        ]
        let history = try FirmwareHistoryService.parse(data: JSONSerialization.data(withJSONObject: document),
            deviceIdentifier: deviceID, now: ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!)
        let older = try XCTUnwrap(history.releases.first?.firmware(deviceIdentifier: deviceID, name: deviceName))
        let latest = DeviceFirmware(id: deviceID, name: deviceName, version: "26.1", build: "23B100",
            downloadURL: URL(string: "https://updates.cdn-apple.com/firmware/iPhone16_1_26.1_23B100_Restore.ipsw")!,
            fileSize: 10_234_567_890, sha1: latestChecksum)

        let manager = DownloadManager(stateDirectory: state, destinationDirectory: destination)
        manager.pause()
        manager.enqueue([latest, older])
        manager.enqueue([older])
        XCTAssertEqual(manager.items.count, 2)
        XCTAssertEqual(Set(manager.items.map(\.id)).count, 2)
        XCTAssertEqual(Set(manager.items.map(\.filename)).count, 2)
        XCTAssertEqual(Set(manager.items.map(\.build)), ["23A100", "23B100"])
        XCTAssertTrue(manager.items.allSatisfy { $0.status == .paused && $0.downloadedBytes == 0 })
        manager.shutdown()

        let restored = DownloadManager(stateDirectory: state, destinationDirectory: destination)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.items, manager.items)
        let restoredOlder = try XCTUnwrap(restored.items.first { $0.build == "23A100" })
        let restoredLatest = try XCTUnwrap(restored.items.first { $0.build == "23B100" })
        XCTAssertEqual(restoredOlder.version, "26.0")
        XCTAssertEqual(restoredOlder.modelIdentifiers, [deviceID])
        XCTAssertEqual(restoredOlder.expectedBytes, 9_123_456_789)
        XCTAssertEqual(restoredOlder.sha1, olderChecksum)
        XCTAssertEqual(restoredLatest.expectedBytes, 10_234_567_890)
        XCTAssertEqual(restoredLatest.sha1, latestChecksum)
    }

    @MainActor
    func testUntrustedURLFailsBeforeStartingTransfer() throws {
        let folder = try temporaryFolder()
        let manager = DownloadManager(stateDirectory: folder.appendingPathComponent("State"), destinationDirectory: folder)
        manager.pause()
        manager.enqueue([firmware("iPad1,1", url: "https://apple.com.evil.example/firmware.ipsw")])
        XCTAssertEqual(manager.items.first?.status, .failed)
        XCTAssertTrue(manager.items.first?.errorMessage?.contains("Apple HTTPS") == true)
        manager.shutdown()
    }

    @MainActor
    func testRemovingQueueEntryPreservesLocalFirmwareByDefault() throws {
        let folder = try temporaryFolder()
        let local = folder.appendingPathComponent("already-downloaded.ipsw")
        try Data("keep me".utf8).write(to: local)
        let image = firmware("iPhone15,2")
        let item = DownloadItem(id: DownloadManager.identifier(for: image.downloadURL), name: image.name,
                                modelIdentifiers: [image.id], version: image.version, build: image.build,
                                url: image.downloadURL, filename: local.lastPathComponent, status: .ready,
                                completedAt: Date(), localPath: local.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SnapshotFixture(items: [item], destinationDirectory: folder))
            .write(to: folder.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(stateDirectory: folder, destinationDirectory: folder)
        XCTAssertEqual(manager.localURL(for: manager.items[0]), local)
        manager.remove(manager.items[0].id, deleteFile: false)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        manager.shutdown()
    }

    func testChecksumAndSizeValidationAcceptsOnlyMatchingArchive() throws {
        let file = try temporaryFolder().appendingPathComponent("test.download")
        let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("fixture archive".utf8)
        try bytes.write(to: file)
        let digest = Insecure.SHA1.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try DownloadManager.validate(file: file, expectedBytes: Int64(bytes.count), sha1: hex))
        XCTAssertNoThrow(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: Data(digest).base64EncodedString()))
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: Int64(bytes.count + 1), sha1: hex))
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: String(repeating: "0", count: 40)))
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: "not-a-checksum"))
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: nil))
    }

    func testHTMLAndEmptyResponsesAreRejectedWithoutCatalogChecksum() throws {
        let file = try temporaryFolder().appendingPathComponent("test.download")
        try Data("<html>server unavailable</html>".utf8).write(to: file)
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: nil))
        try Data().write(to: file)
        XCTAssertThrowsError(try DownloadManager.validate(file: file, expectedBytes: nil, sha1: nil))
    }

    func testExistingFilenameIsNeverOverwritten() throws {
        let folder = try temporaryFolder()
        let original = folder.appendingPathComponent("restore.ipsw")
        try Data("original".utf8).write(to: original)
        let candidate = try DownloadManager.availableDestination(in: folder, filename: "restore.ipsw", id: "123456789abcdef")
        XCTAssertEqual(candidate.lastPathComponent, "restore-12345678.ipsw")
        try Data("second".utf8).write(to: candidate)
        let next = try DownloadManager.availableDestination(in: folder, filename: "restore.ipsw", id: "123456789abcdef")
        XCTAssertEqual(next.lastPathComponent, "restore-12345678-2.ipsw")
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testCapacityCheckRejectsImpossibleAndOverflowingRequests() throws {
        let folder = try temporaryFolder()
        XCTAssertThrowsError(try DownloadManager.requireCapacity(at: folder, remainingBytes: Int64.max, reserveBytes: 1))
        XCTAssertNoThrow(try DownloadManager.requireCapacity(at: folder, remainingBytes: 0, reserveBytes: 0))
        XCTAssertNoThrow(try DownloadManager.requireTransferCapacity(destination: folder, expectedBytes: 0, downloadedBytes: 0, reserveBytes: 0))
    }

    func testOnlyTransientNetworkErrorsAllowAutomaticRetry() {
        XCTAssertTrue(DownloadManager.isTransient(URLError(.timedOut)))
        XCTAssertTrue(DownloadManager.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(DownloadManager.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(DownloadManager.isTransient(URLError(.cancelled)))
    }

    @MainActor
    func testUnreadableQueueIsPreservedBeforeRecoveryWrites() throws {
        let folder = try temporaryFolder()
        let original = Data("{ broken queue data".utf8)
        try original.write(to: folder.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(stateDirectory: folder, destinationDirectory: folder)
        manager.pause()
        XCTAssertNotNil(manager.persistenceError)
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("downloads-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        manager.shutdown()
    }

    @MainActor
    func testMissingCompletedFileRequeuesAfterRestartAndCatalogCheck() throws {
        let folder = try temporaryFolder()
        let image = firmware("iPhone15,2")
        let item = DownloadItem(id: DownloadManager.identifier(for: image.downloadURL), name: image.name,
                                modelIdentifiers: [image.id], version: image.version, build: image.build,
                                url: image.downloadURL, filename: "missing.ipsw", status: .ready,
                                completedAt: Date(), localPath: folder.appendingPathComponent("missing.ipsw").path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SnapshotFixture(items: [item], destinationDirectory: folder))
            .write(to: folder.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(stateDirectory: folder, destinationDirectory: folder)
        XCTAssertEqual(manager.items[0].status, .failed)
        manager.enqueue([image])
        XCTAssertEqual(manager.items[0].status, .paused)
        XCTAssertNil(manager.items[0].completedAt)
        manager.shutdown()
    }

    @MainActor
    func testUnsignedCleanupRemovesOnlyManagedCollisionFileAndPersistsAutoDownloadSuppression() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let image = firmware("iPhone15,2")
        let id = DownloadManager.identifier(for: image.downloadURL)
        let item = try completedFirmware(in: destination, filename: "shared-\(id.prefix(8))-2.ipsw")
        let unrelated = destination.appendingPathComponent("shared.ipsw")
        try Data("pre-existing user file".utf8).write(to: unrelated)
        let state = root.appendingPathComponent("State", isDirectory: true)
        let manager = try completedQueue([item], state: state, destination: destination)
        var removedPaths: [String] = []
        manager.removeCompletedFile = { file in
            removedPaths.append(file.path)
            try FileManager.default.removeItem(at: file) // Temporary test fixture only.
        }
        let result = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(removedPaths, [try XCTUnwrap(item.localPath)])
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localPath)))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("pre-existing user file".utf8))
        manager.shutdown()

        let restored = DownloadManager(stateDirectory: state, destinationDirectory: destination)
        defer { restored.shutdown() }
        restored.enqueue([image], automatically: true)
        XCTAssertTrue(restored.items.isEmpty, "Scheduled checks must not redownload a successfully cleaned release.")
        restored.enqueue([image])
        XCTAssertEqual(restored.items.count, 1, "An explicit request can bypass cleanup suppression.")
        XCTAssertEqual(restored.items[0].status, .paused)
        restored.remove(item.id, deleteFile: false)
        restored.enqueue([image], automatically: true)
        XCTAssertEqual(restored.items.count, 1, "The explicit request must also clear the persisted suppression.")
    }

    @MainActor
    func testUnsignedCleanupFailureKeepsFileAndQueueWithoutSuppressingAutomaticDownloads() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let item = try completedFirmware(in: destination)
        let manager = try completedQueue([item], state: root.appendingPathComponent("State"), destination: destination)
        defer { manager.shutdown() }
        manager.removeCompletedFile = { _ in throw CocoaError(.fileWriteNoPermission) }
        let result = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        guard case .failed = result else { return XCTFail("Expected an explicit removal failure, got \(result)") }
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items[0].status, .ready)
        XCTAssertNotNil(manager.items[0].errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localPath)))
        manager.remove(item.id, deleteFile: false)
        manager.enqueue([firmware("iPhone15,2")], automatically: true)
        XCTAssertEqual(manager.items.count, 1)
    }

    @MainActor
    func testUnsignedCleanupCannotDeleteWhenQueueWriteFails() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let item = try completedFirmware(in: destination)
        let state = root.appendingPathComponent("State", isDirectory: true)
        let manager = try completedQueue([item], state: state, destination: destination)
        defer { manager.shutdown() }
        let queueFile = state.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: queueFile)
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        var removalWasCalled = false
        manager.removeCompletedFile = { _ in removalWasCalled = true }
        let result = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        guard case .failed = result else { return XCTFail("Cleanup must fail when its suppression cannot be persisted.") }
        XCTAssertFalse(removalWasCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localPath)))
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items[0].status, .ready)
        XCTAssertNotNil(manager.persistenceError)

        try FileManager.default.removeItem(at: queueFile)
        manager.remove(item.id, deleteFile: false)
        manager.enqueue([firmware("iPhone15,2")], automatically: true)
        XCTAssertEqual(manager.items.count, 1, "A failed cleanup must roll back its in-memory suppression.")
    }

    @MainActor
    func testUnsignedCleanupRejectsUnmanagedPathsAndUnfinishedEntries() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let original = try completedFirmware(in: destination)
        let unrelated = root.appendingPathComponent("personal.ipsw")
        try Data("unrelated personal file".utf8).write(to: unrelated)
        var unfinished = original; unfinished.status = .paused
        var missingDestination = original; missingDestination.destinationPath = nil
        var outsideDestination = original; outsideDestination.localPath = unrelated.path
        var renamedFile = original
        renamedFile.localPath = unrelated.path; renamedFile.destinationPath = root.path; renamedFile.filename = unrelated.lastPathComponent
        var forgedID = original; forgedID.id = "forged"
        var unverified = original; unverified.completedAt = nil
        for (number, item) in [unfinished, missingDestination, outsideDestination, renamedFile, forgedID, unverified].enumerated() {
            let manager = try completedQueue([item], state: root.appendingPathComponent("State-\(number)"), destination: destination)
            var removalWasCalled = false
            manager.removeCompletedFile = { _ in removalWasCalled = true }
            let result = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
            XCTAssertEqual(result, .notEligible)
            XCTAssertFalse(removalWasCalled)
            XCTAssertEqual(manager.items.count, 1)
            manager.shutdown()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(original.localPath)))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated personal file".utf8))
    }

    @MainActor
    func testUnsignedCleanupRejectsSymlinkAndChangedFileContents() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let item = try completedFirmware(in: destination)
        let file = URL(fileURLWithPath: try XCTUnwrap(item.localPath))
        let realFile = destination.appendingPathComponent("unrelated.ipsw")
        try FileManager.default.moveItem(at: file, to: realFile)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: realFile)
        let manager = try completedQueue([item], state: root.appendingPathComponent("State"), destination: destination)
        defer { manager.shutdown() }
        var removalWasCalled = false
        manager.removeCompletedFile = { _ in removalWasCalled = true }
        let symlinkResult = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(symlinkResult, .notEligible)
        XCTAssertFalse(removalWasCalled)

        try FileManager.default.removeItem(at: file)
        var changedBytes = try Data(contentsOf: realFile)
        changedBytes[changedBytes.count - 1] ^= 1
        try changedBytes.write(to: file)
        let changedResult = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        guard case .failed = changedResult else { return XCTFail("A replaced file must fail checksum verification.") }
        XCTAssertFalse(removalWasCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFile.path))
    }

    @MainActor
    func testUnsignedCleanupMissingOrCancelledFileKeepsQueue() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let item = try completedFirmware(in: destination)
        let manager = try completedQueue([item], state: root.appendingPathComponent("State"), destination: destination)
        defer { manager.shutdown() }
        var removalWasCalled = false
        manager.removeCompletedFile = { _ in removalWasCalled = true }
        let operation = Task { @MainActor in await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture) }
        operation.cancel()
        let cancelled = await operation.value
        XCTAssertEqual(cancelled, .notEligible)
        XCTAssertFalse(removalWasCalled)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(item.localPath))
        let missing = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertFalse(removalWasCalled)
    }

    @MainActor
    func testUnsignedCleanupRejectsExpiredSigningApproval() async throws {
        let root = try temporaryFolder()
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let item = try completedFirmware(in: destination)
        let manager = try completedQueue([item], state: root.appendingPathComponent("State"), destination: destination)
        defer { manager.shutdown() }
        var removalWasCalled = false
        manager.removeCompletedFile = { _ in removalWasCalled = true }
        let result = await manager.removeUnsignedDownload(item.id, signingApprovalExpiresAt: .distantPast)
        XCTAssertEqual(result, .notEligible)
        XCTAssertFalse(removalWasCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localPath)))
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertNil(manager.items[0].errorMessage)
    }

    func testFilenameCannotIntroduceDirectoryTraversal() {
        let name = DownloadManager.safeFilename(for: URL(string: "https://updates.cdn-apple.com/%2Ftmp%2Fescape.ipsw")!, fallback: "abc")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertTrue(name.hasSuffix(".ipsw"))
    }
}
