import XCTest
@testable import FirmwareCore

final class FirmwareDestinationTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("FirmwareDestinationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testFreshSettingsUseExistingConfiguratorFirmwareDirectory() throws {
        let home = try temporaryHome()
        let configurator = FirmwareDestination.configuratorDirectory(homeDirectory: home)
        XCTAssertEqual(configurator.path, home.path + "/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware")
        try FileManager.default.createDirectory(at: configurator, withIntermediateDirectories: true)
        XCTAssertEqual(FirmwareDestination.preferredDirectory(homeDirectory: home, downloadsDirectory: home.appendingPathComponent("Downloads")), configurator)
    }

    func testMissingConfiguratorFallsBackWithoutCreatingFolders() throws {
        let home = try temporaryHome()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let configurator = FirmwareDestination.configuratorDirectory(homeDirectory: home)
        XCTAssertEqual(FirmwareDestination.preferredDirectory(homeDirectory: home, downloadsDirectory: downloads), downloads.appendingPathComponent("RestoreDock", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
    }

    func testSavedCustomAndPreviousDefaultDestinationsArePreserved() throws {
        let home = try temporaryHome()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let configurator = FirmwareDestination.configuratorDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: configurator, withIntermediateDirectories: true)
        for saved in [home.appendingPathComponent("Custom Library", isDirectory: true), downloads.appendingPathComponent("Firmware Shelf", isDirectory: true)] {
            XCTAssertEqual(FirmwareDestination.preferredDirectory(savedPath: saved.path, homeDirectory: home, downloadsDirectory: downloads), saved)
        }
    }

    func testExistingPreviousDefaultIsReusedWithoutSavedSettings() throws {
        let home = try temporaryHome()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let previousDefault = downloads.appendingPathComponent("Firmware Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: previousDefault, withIntermediateDirectories: true)
        XCTAssertEqual(FirmwareDestination.preferredDirectory(homeDirectory: home, downloadsDirectory: downloads), previousDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("RestoreDock").path))
    }

    func testAFileAtPreviousDefaultDoesNotPreventNewDefault() throws {
        let home = try temporaryHome()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let previousDefault = downloads.appendingPathComponent("Firmware Shelf", isDirectory: true)
        try Data("existing file".utf8).write(to: previousDefault)
        XCTAssertEqual(FirmwareDestination.preferredDirectory(homeDirectory: home, downloadsDirectory: downloads), downloads.appendingPathComponent("RestoreDock", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: previousDefault), Data("existing file".utf8))
    }

    func testAFileAtConfiguratorPathIsNotUsedAsDefault() throws {
        let home = try temporaryHome()
        let configurator = FirmwareDestination.configuratorDirectory(homeDirectory: home)
        try FileManager.default.createDirectory(at: configurator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing file".utf8).write(to: configurator)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        XCTAssertFalse(FirmwareDestination.directoryExists(at: configurator))
        XCTAssertEqual(FirmwareDestination.preferredDirectory(homeDirectory: home, downloadsDirectory: downloads), downloads.appendingPathComponent("RestoreDock", isDirectory: true))
        XCTAssertThrowsError(try FirmwareDestination.prepareDirectory(at: configurator, createIfNeeded: true))
        XCTAssertEqual(try Data(contentsOf: configurator), Data("existing file".utf8))
    }

    func testExplicitCreateIsRequiredForMissingConfiguratorDirectory() throws {
        let home = try temporaryHome()
        let configurator = FirmwareDestination.configuratorDirectory(homeDirectory: home)
        XCTAssertThrowsError(try FirmwareDestination.prepareDirectory(at: configurator, createIfNeeded: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.path))
        XCTAssertEqual(try FirmwareDestination.prepareDirectory(at: configurator, createIfNeeded: true), configurator)
        XCTAssertTrue(FirmwareDestination.directoryExists(at: configurator))
        XCTAssertNoThrow(try FirmwareDestination.prepareDirectory(at: configurator, createIfNeeded: false))
    }

    func testReadOnlyFolderIsRejected() throws {
        let home = try temporaryHome()
        let readOnly = home.appendingPathComponent("ReadOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        XCTAssertThrowsError(try FirmwareDestination.prepareDirectory(at: readOnly, createIfNeeded: false)) { error in
            XCTAssertEqual(error as? DestinationError, .notWritable(readOnly.path))
        }
    }

    func testRemoteURLIsRejected() {
        XCTAssertThrowsError(try FirmwareDestination.prepareDirectory(at: URL(string: "https://example.com/firmware")!, createIfNeeded: true))
    }

    func testSameDirectoryRecognizesSymlink() throws {
        let home = try temporaryHome()
        let folder = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = home.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        XCTAssertTrue(FirmwareDestination.sameDirectory(folder, alias))
    }
}
