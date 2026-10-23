import XCTest
import CryptoKit
@testable import FirmwareCore

final class FirmwareImportTests: XCTestCase {
    private let appleURL = URL(string: "https://updates.cdn-apple.com/firmware/Original_Restore.ipsw")!
    private let model = "iPhone15,2"

    private struct Fixture: Sendable {
        let folder: URL
        let file: URL
        let manifest: Data
        let bytes: Data
        let sha1: String
    }

    private struct Snapshot: Encodable {
        let version = 1
        let items: [DownloadItem]
        let isPaused = true
        let destinationDirectory: URL
        let reserveBytes: Int64 = 0
    }

    private func fixture(identifiers: [String] = ["iPhone15,2"], realZIP: Bool = false) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FirmwareImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("My renamed firmware.ipsw")
        let manifest = try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": "26.0", "ProductBuildVersion": "23A100", "SupportedProductTypes": identifiers
        ], format: .xml, options: 0)
        if realZIP {
            try manifest.write(to: folder.appendingPathComponent("BuildManifest.plist"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", file.path, "BuildManifest.plist"]
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FirmwareImportError.message("Could not create ZIP test fixture.") }
        } else {
            try (Data([0x50, 0x4b, 0x03, 0x04]) + Data("small verified fixture".utf8)).write(to: file)
        }
        let bytes = try Data(contentsOf: file)
        let sha1 = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Fixture(folder: folder, file: file, manifest: manifest, bytes: bytes, sha1: sha1)
    }

    private func history(_ fixture: Fixture, identifier: String = "iPhone15,2", sha1: String? = nil,
                         size: Int64? = nil, url: URL? = nil, signed: Bool = false) -> FirmwareHistory {
        FirmwareHistory(deviceIdentifier: identifier, deviceName: "Test iPhone", releases: [
            FirmwareRelease(version: "26.0", build: "23A100", fileSize: size ?? Int64(fixture.bytes.count),
                isSigned: signed, downloadURL: url ?? appleURL, sha1: sha1 ?? fixture.sha1)
        ], fetchedAt: Date())
    }

    private func verifier(_ fixture: Fixture, history: FirmwareHistory? = nil) -> FirmwareImportService {
        let history = history ?? self.history(fixture)
        return FirmwareImportService(readManifest: { _ in fixture.manifest }, fetchHistory: { _ in history })
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { }
    }

    func testRealZIPManifestAndUnsignedMetadataVerifyRenamedFileInPlace() async throws {
        let fixture = try fixture(realZIP: true)
        let history = history(fixture)
        let service = FirmwareImportService(fetchHistory: { _ in history })
        let verified = try await service.verify(file: fixture.file)
        XCTAssertEqual(verified.version, "26.0")
        XCTAssertEqual(verified.build, "23A100")
        XCTAssertEqual(verified.modelIdentifiers, [model])
        XCTAssertEqual(verified.fileURL, fixture.file.standardizedFileURL)
        XCTAssertEqual(verified.bytes, Int64(fixture.bytes.count))
        XCTAssertEqual(verified.sha1, fixture.sha1)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.bytes)
    }

    func testAllManifestIdentifiersRemainLinkedWhenSomeMetadataIsUnavailable() async throws {
        let fixture = try fixture(identifiers: ["iPhone15,2", "iPhone15,3", "iPhone15,3", "AppleTV1,1"])
        let history = history(fixture)
        let service = FirmwareImportService(readManifest: { _ in fixture.manifest }, fetchHistory: { id in
            if id == "iPhone15,2" { return history }
            throw URLError(.notConnectedToInternet)
        })
        let result = try await service.verify(file: fixture.file)
        XCTAssertEqual(result.modelIdentifiers, ["iPhone15,2", "iPhone15,3"])
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testConflictingMatchingModelsAreRejected() async throws {
        let fixture = try fixture(identifiers: ["iPhone15,2", "iPhone15,3"])
        let first = history(fixture)
        let second = history(fixture, identifier: "iPhone15,3", sha1: String(repeating: "a", count: 40))
        let service = FirmwareImportService(readManifest: { _ in fixture.manifest }, fetchHistory: { id in
            id == "iPhone15,2" ? first : second
        })
        await expectFailure { _ = try await service.verify(file: fixture.file) }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.bytes)
    }

    func testWrongChecksumAndSizeAreRejected() async throws {
        let fixture = try fixture()
        let wrongHash = verifier(fixture, history: history(fixture, sha1: String(repeating: "0", count: 40)))
        await expectFailure { _ = try await wrongHash.verify(file: fixture.file) }
        let wrongSize = verifier(fixture, history: history(fixture, size: Int64(fixture.bytes.count + 1)))
        await expectFailure { _ = try await wrongSize.verify(file: fixture.file) }
    }

    func testMissingChecksumAndUnapprovedURLCannotVerify() async throws {
        let fixture = try fixture()
        let invalid = FirmwareHistory(deviceIdentifier: model, deviceName: "Test", releases: [
            FirmwareRelease(version: "26.0", build: "23A100", fileSize: Int64(fixture.bytes.count),
                isSigned: false, downloadURL: URL(string: "https://example.com/test.ipsw"), sha1: fixture.sha1),
            FirmwareRelease(version: "26.0", build: "23A100", fileSize: Int64(fixture.bytes.count),
                isSigned: false, downloadURL: appleURL, sha1: nil)
        ], fetchedAt: Date())
        await expectFailure { _ = try await self.verifier(fixture, history: invalid).verify(file: fixture.file) }
    }

    func testManifestBoundsAndUnsupportedModelAreRejected() throws {
        XCTAssertThrowsError(try FirmwareImportService.parseManifest(Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)))
        let fixture = try fixture(identifiers: ["AppleTV1,1", "invalid"])
        XCTAssertThrowsError(try FirmwareImportService.parseManifest(fixture.manifest))
    }

    func testSymbolicLinksAndDirectoriesAreRejected() async throws {
        let fixture = try fixture()
        let link = fixture.folder.appendingPathComponent("link.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        await expectFailure { _ = try await self.verifier(fixture).verify(file: link) }
        let folder = fixture.folder.appendingPathComponent("directory.ipsw", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await expectFailure { _ = try await self.verifier(fixture).verify(file: folder) }
    }

    func testFileChangedDuringMetadataFetchIsRejected() async throws {
        let fixture = try fixture()
        let history = history(fixture)
        let service = FirmwareImportService(readManifest: { _ in fixture.manifest }, fetchHistory: { _ in
            try (fixture.bytes + Data([1])).write(to: fixture.file)
            return history
        })
        await expectFailure { _ = try await service.verify(file: fixture.file) }
    }

    func testCancellationStopsVerification() async throws {
        let fixture = try fixture()
        let history = history(fixture)
        let service = FirmwareImportService(readManifest: { _ in fixture.manifest }, fetchHistory: { _ in
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return history
        })
        let task = Task { try await service.verify(file: fixture.file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.bytes)
    }

    func testDiscoveryDeduplicatesAndSkipsHiddenFilesPackagesAndSymlinks() async throws {
        let fixture = try fixture()
        let nested = fixture.folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("nested.IPSW")
        try fixture.bytes.write(to: nestedFile)
        try fixture.bytes.write(to: fixture.folder.appendingPathComponent(".hidden.ipsw"))
        try FileManager.default.createSymbolicLink(at: fixture.folder.appendingPathComponent("linked.ipsw"), withDestinationURL: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.folder.appendingPathComponent("linked-folder"), withDestinationURL: nested)
        let package = fixture.folder.appendingPathComponent("Skip.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try fixture.bytes.write(to: package.appendingPathComponent("package.ipsw"))
        let result = try await FirmwareImportService.discover(in: [fixture.folder, fixture.file])
        XCTAssertEqual(Set(result), Set([fixture.file.standardizedFileURL, nestedFile.standardizedFileURL]))
    }

    @MainActor
    func testRegistrationPersistsInPlaceAndAutomaticEnqueueDoesNotDuplicate() async throws {
        let fixture = try fixture()
        let verified = try await verifier(fixture).verify(file: fixture.file)
        let state = fixture.folder.appendingPathComponent("State", isDirectory: true)
        let manager = DownloadManager(stateDirectory: state, destinationDirectory: fixture.folder.appendingPathComponent("Other"))
        manager.pause()
        let id = DownloadManager.identifier(for: appleURL)
        XCTAssertEqual(try manager.registerImport(verified), .imported(id))
        let imported = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(imported.localPath, fixture.file.path)
        XCTAssertEqual(imported.filename, "My renamed firmware.ipsw")
        XCTAssertNotNil(imported.importedAt)
        XCTAssertFalse(imported.allowsAutomaticCleanup)
        manager.enqueue([DeviceFirmware(id: model, name: "Test", version: "26.0", build: "23A100",
            downloadURL: appleURL, fileSize: Int64(fixture.bytes.count), sha1: fixture.sha1)], automatically: true)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.status, .ready)
        XCTAssertEqual(try manager.registerImport(verified, allowAutomaticCleanup: true), .alreadyAvailable(id))
        XCTAssertFalse(manager.items[0].allowsAutomaticCleanup)
        let expandedManifest = try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": "26.0", "ProductBuildVersion": "23A100", "SupportedProductTypes": [model, "iPhone15,3"]
        ], format: .xml, options: 0)
        let histories = [model: history(fixture), "iPhone15,3": history(fixture, identifier: "iPhone15,3")]
        let expandedVerifier = FirmwareImportService(readManifest: { _ in expandedManifest }, fetchHistory: { histories[$0]! })
        let expanded = try await expandedVerifier.verify(file: fixture.file)
        XCTAssertEqual(try manager.registerImport(expanded, allowAutomaticCleanup: true), .alreadyAvailable(id))
        XCTAssertEqual(manager.items[0].modelIdentifiers, [model, "iPhone15,3"])
        XCTAssertFalse(manager.items[0].allowsAutomaticCleanup)
        manager.shutdown()
        let restored = DownloadManager(stateDirectory: state, destinationDirectory: fixture.folder)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.items.first?.localPath, fixture.file.path)
        XCTAssertFalse(restored.items[0].allowsAutomaticCleanup)
    }

    @MainActor
    func testRegistrationReplacesPausedQueueWithoutStartingTransfer() async throws {
        let fixture = try fixture()
        let verified = try await verifier(fixture).verify(file: fixture.file)
        let manager = DownloadManager(stateDirectory: fixture.folder.appendingPathComponent("State"), destinationDirectory: fixture.folder)
        manager.pause()
        defer { manager.shutdown() }
        manager.enqueue([DeviceFirmware(id: model, name: "Test", version: "26.0", build: "23A100", downloadURL: appleURL)])
        XCTAssertEqual(manager.items[0].status, .paused)
        _ = try manager.registerImport(verified)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items[0].status, .ready)
        XCTAssertTrue(manager.isPaused)
    }

    @MainActor
    func testChangedFileCannotBeRegisteredAndPersistenceFailureKeepsQueue() async throws {
        let fixture = try fixture()
        let verified = try await verifier(fixture).verify(file: fixture.file)
        let state = fixture.folder.appendingPathComponent("State")
        let manager = DownloadManager(stateDirectory: state, destinationDirectory: fixture.folder)
        manager.pause()
        defer { manager.shutdown() }
        try FileManager.default.removeItem(at: state.appendingPathComponent("downloads.json"))
        try FileManager.default.createDirectory(at: state.appendingPathComponent("downloads.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.registerImport(verified))
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.bytes)
        try FileManager.default.removeItem(at: state.appendingPathComponent("downloads.json"))
        try (fixture.bytes + Data([1])).write(to: fixture.file)
        XCTAssertThrowsError(try manager.registerImport(verified))
        XCTAssertTrue(manager.items.isEmpty)
    }

    @MainActor
    func testImportedCleanupRequiresExplicitPermissionAndSupportsRenamedFile() async throws {
        let fixture = try fixture()
        let verified = try await verifier(fixture).verify(file: fixture.file)
        let protected = DownloadManager(stateDirectory: fixture.folder.appendingPathComponent("Protected"), destinationDirectory: fixture.folder)
        protected.pause()
        let id = DownloadManager.identifier(for: appleURL)
        _ = try protected.registerImport(verified)
        let kept = await protected.removeUnsignedDownload(id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(kept, .notEligible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        protected.shutdown()

        let allowed = DownloadManager(stateDirectory: fixture.folder.appendingPathComponent("Allowed"), destinationDirectory: fixture.folder)
        allowed.pause()
        defer { allowed.shutdown() }
        _ = try allowed.registerImport(verified, allowAutomaticCleanup: true)
        let removed = await allowed.removeUnsignedDownload(id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(removed, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @MainActor
    func testSamePhysicalFileWithDifferentMetadataURLIsNotRegisteredTwice() async throws {
        let fixture = try fixture()
        let first = try await verifier(fixture).verify(file: fixture.file)
        let alternateURL = URL(string: "https://updates.cdn-apple.com/alternate/Original_Restore.ipsw")!
        let second = try await verifier(fixture, history: history(fixture, url: alternateURL)).verify(file: fixture.file)
        let manager = DownloadManager(stateDirectory: fixture.folder.appendingPathComponent("State"), destinationDirectory: fixture.folder)
        manager.pause()
        defer { manager.shutdown() }
        _ = try manager.registerImport(first)
        XCTAssertEqual(try manager.registerImport(second), .alreadyAvailable(DownloadManager.identifier(for: appleURL)))
        XCTAssertEqual(manager.items.count, 1)
    }

    @MainActor
    func testCleanupRefusesLegacyDuplicateEntryReferencingProtectedFile() async throws {
        let fixture = try fixture()
        let verified = try await verifier(fixture).verify(file: fixture.file)
        let state = fixture.folder.appendingPathComponent("State")
        let manager = DownloadManager(stateDirectory: state, destinationDirectory: fixture.folder)
        manager.pause()
        _ = try manager.registerImport(verified, allowAutomaticCleanup: true)
        let first = try XCTUnwrap(manager.items.first)
        manager.shutdown()
        var second = first
        second.url = URL(string: "https://updates.cdn-apple.com/alternate/shared.ipsw")!
        second.id = DownloadManager.identifier(for: second.url)
        second.importedCleanupAllowed = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Snapshot(items: [first, second], destinationDirectory: fixture.folder))
            .write(to: state.appendingPathComponent("downloads.json"), options: .atomic)
        let restored = DownloadManager(stateDirectory: state, destinationDirectory: fixture.folder)
        defer { restored.shutdown() }
        let result = await restored.removeUnsignedDownload(first.id, signingApprovalExpiresAt: .distantFuture)
        XCTAssertEqual(result, .notEligible)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testLegacyDownloadsRemainCleanupEligible() throws {
        let item = DownloadItem(id: "old", name: "Old", modelIdentifiers: [model], version: "26.0", build: "23A100",
            url: appleURL, filename: "original.ipsw")
        let data = try JSONEncoder().encode(item)
        XCTAssertTrue(try JSONDecoder().decode(DownloadItem.self, from: data).allowsAutomaticCleanup)
    }
}
