import XCTest
@testable import FirmwareCore

final class FirmwareModelScanTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirmwareModelScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func manifest(_ identifiers: [String], version: String = "26.0", build: String = "23A100") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": version, "ProductBuildVersion": build, "SupportedProductTypes": identifiers
        ], format: .xml, options: 0)
    }

    private func archive(in folder: URL, name: String = "Renamed work firmware.ipsw",
                         identifiers: [String] = ["iPhone15,2"], version: String = "26.0", build: String = "23A100") throws -> URL {
        let file = folder.appendingPathComponent(name)
        try manifest(identifiers, version: version, build: build).write(to: folder.appendingPathComponent("BuildManifest.plist"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", file.path, "BuildManifest.plist"]
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FirmwareImportError.message("Could not make scan test archive.") }
        return file
    }

    func testRenamedRealIPSWIdentifiesOnlySupportedModelsWithoutChangingFile() async throws {
        let directory = try folder()
        let file = try archive(in: directory, identifiers: ["iPhone15,2", "iPad16,3", "iPhone15,2", "AppleTV1,1", "invalid"])
        let before = try Data(contentsOf: file)
        let report = try await FirmwareModelScanService().scan(directory: directory)
        XCTAssertEqual(report.scannedFileCount, 1)
        XCTAssertTrue(report.issues.isEmpty)
        let result = try XCTUnwrap(report.files.first)
        XCTAssertEqual(result.id, file.standardizedFileURL.path)
        XCTAssertEqual(result.version, "26.0")
        XCTAssertEqual(result.build, "23A100")
        XCTAssertEqual(result.modelIdentifiers, ["iPad16,3", "iPhone15,2"])
        XCTAssertEqual(report.modelIdentifiers, ["iPad16,3", "iPhone15,2"])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSharedModelsAcrossVersionsAndNestedFoldersAreDeduplicated() async throws {
        let directory = try folder()
        _ = try archive(in: directory, name: "first.ipsw", identifiers: ["iPhone15,2", "iPhone15,3"])
        let nested = directory.appendingPathComponent("Older", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try archive(in: nested, name: "second.IPSW", identifiers: ["iPhone15,2"], version: "25.6", build: "22G100")
        let report = try await FirmwareModelScanService().scan(directory: directory)
        XCTAssertEqual(report.files.count, 2)
        XCTAssertEqual(report.modelIdentifiers, ["iPhone15,2", "iPhone15,3"])
        XCTAssertEqual(Set(report.files.map(\.version)), ["26.0", "25.6"])
    }

    func testBadEmptyAndUnsupportedArchivesDoNotHideValidFiles() async throws {
        let directory = try folder()
        let valid = try archive(in: directory, name: "valid.ipsw")
        _ = try archive(in: directory, name: "unsupported.ipsw", identifiers: ["AppleTV1,1"])
        try Data("not a zip".utf8).write(to: directory.appendingPathComponent("bad.ipsw"))
        try Data().write(to: directory.appendingPathComponent("empty.ipsw"))
        try Data("ignore".utf8).write(to: directory.appendingPathComponent("readme.txt"))
        let report = try await FirmwareModelScanService().scan(directory: directory)
        XCTAssertEqual(report.files.map(\.fileURL), [valid.standardizedFileURL])
        XCTAssertEqual(report.scannedFileCount, 4)
        XCTAssertEqual(Set(report.issues.map { $0.fileURL.lastPathComponent }), ["bad.ipsw", "empty.ipsw", "unsupported.ipsw"])
        XCTAssertTrue(report.issues.allSatisfy { !$0.message.isEmpty })
    }

    func testHiddenPackagesSymlinksAndHardLinkAliasesAreNotReadTwice() async throws {
        let directory = try folder()
        let file = try archive(in: directory, name: "original.ipsw")
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("z-hardlink.ipsw"))
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(".hidden.ipsw"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("symbolic.ipsw"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("cycle"), withDestinationURL: directory)
        let package = directory.appendingPathComponent("Skip.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: file, to: package.appendingPathComponent("nested.ipsw"))
        let report = try await FirmwareModelScanService().scan(directory: directory)
        XCTAssertEqual(report.scannedFileCount, 1)
        XCTAssertEqual(report.files.map(\.fileURL), [file.standardizedFileURL])
    }

    func testFileChangedDuringManifestReadIsReportedAndNotSuggested() async throws {
        let directory = try folder()
        let file = try archive(in: directory)
        let data = try manifest(["iPhone15,2"])
        let service = FirmwareModelScanService(readManifest: { file in
            let changed = try Data(contentsOf: file) + Data([1])
            try changed.write(to: file)
            return data
        })
        let report = try await service.scan(directory: directory)
        XCTAssertTrue(report.files.isEmpty)
        XCTAssertTrue(report.modelIdentifiers.isEmpty)
        XCTAssertEqual(report.issues.first?.fileURL, file.standardizedFileURL)
        XCTAssertTrue(report.issues.first?.message.contains("changed") == true)
    }

    func testCancellationDuringManifestReadCancelsWholeScan() async throws {
        let directory = try folder()
        _ = try archive(in: directory)
        let started = expectation(description: "Manifest reader started")
        let service = FirmwareModelScanService(readManifest: { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return Data()
        })
        let task = Task { try await service.scan(directory: directory) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMissingNonDirectoryAndSymbolicLinkRootsAreRejected() async throws {
        let directory = try folder()
        let file = try archive(in: directory)
        let link = directory.appendingPathComponent("folder-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        for invalid in [directory.appendingPathComponent("Missing"), file, link, URL(string: "https://example.com/firmware")!] {
            do { _ = try await FirmwareModelScanService().scan(directory: invalid); XCTFail("Expected rejection: \(invalid)") }
            catch { }
        }
    }

    func testSuggestionPolicyExcludesUnknownFollowedReviewedAndDuplicateCatalogEntries() {
        let url = URL(string: "https://updates.cdn-apple.com/fixture.ipsw")!
        let older = DeviceFirmware(id: "iPhone15,2", name: "iPhone 14 Pro", version: "26", build: "23A100", downloadURL: url)
        let newer = DeviceFirmware(id: "iPhone18,3", name: "iPhone 17", version: "26", build: "23A100", downloadURL: url)
        let followed = DeviceFirmware(id: "iPhone15,3", name: "iPhone 14 Pro Max", version: "26", build: "23A100", downloadURL: url)
        let reviewed = DeviceFirmware(id: "iPad16,3", name: "iPad Pro", version: "26", build: "23A100", downloadURL: url)
        let unrelated = DeviceFirmware(id: "iPhone14,7", name: "iPhone 14", version: "26", build: "23A100", downloadURL: url)
        let report = FirmwareModelScanReport(files: [FirmwareModelScanFile(
            fileURL: URL(fileURLWithPath: "/tmp/fixture.ipsw"), version: "26", build: "23A100",
            modelIdentifiers: [older.id, newer.id, followed.id, reviewed.id, "iPhone999,9"])])
        let eligible = FirmwareFollowSuggestionPolicy.eligibleDevices(report: report,
            catalog: [older, reviewed, followed, newer, unrelated, older], followedIDs: [followed.id], reviewedIDs: [reviewed.id])
        XCTAssertEqual(eligible.map(\.id), [newer.id, older.id])
        XCTAssertEqual(FirmwareFollowSuggestionPolicy.selectedIDs(
            [older.id, followed.id, reviewed.id, unrelated.id, "iPhone999,9"], eligibleDevices: eligible), [older.id])
        XCTAssertTrue(FirmwareFollowSuggestionPolicy.selectedIDs([], eligibleDevices: eligible).isEmpty)
    }
}
