import Foundation
import Darwin

/// Models declared by an archive's manifest. This is identification only, not
/// evidence that the complete IPSW has passed a checksum or signing check.
public struct FirmwareModelScanFile: Identifiable, Sendable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let version: String
    public let build: String
    public let modelIdentifiers: [String]

    public init(fileURL: URL, version: String, build: String, modelIdentifiers: [String]) {
        self.fileURL = fileURL.standardizedFileURL
        self.version = version
        self.build = build
        self.modelIdentifiers = Array(Set(modelIdentifiers)).sorted()
    }
}

public struct FirmwareModelScanIssue: Identifiable, Sendable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    public let message: String

    public init(fileURL: URL, message: String) {
        self.fileURL = fileURL.standardizedFileURL
        self.message = message
    }
}

public struct FirmwareModelScanReport: Sendable {
    public let files: [FirmwareModelScanFile]
    public let issues: [FirmwareModelScanIssue]
    public var modelIdentifiers: Set<String> { Set(files.flatMap(\.modelIdentifiers)) }
    public var scannedFileCount: Int { files.count + issues.count }

    public init(files: [FirmwareModelScanFile], issues: [FirmwareModelScanIssue] = []) {
        self.files = files
        self.issues = issues
    }
}

/// Reads only BuildManifest.plist from existing archives. It never imports a
/// file, changes the download queue, or contacts a network service.
public struct FirmwareModelScanService: Sendable {
    private let readManifest: @Sendable (URL) async throws -> Data

    public init() {
        readManifest = { try await ManifestReader.read($0) }
    }

    init(readManifest: @escaping @Sendable (URL) async throws -> Data) {
        self.readManifest = readManifest
    }

    public func scan(directory: URL,
                     progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FirmwareModelScanReport {
        try Task.checkCancellation()
        guard directory.isFileURL else {
            throw FirmwareImportError.message("Choose a local firmware folder to scan.")
        }
        let directory = directory.standardizedFileURL
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw FirmwareImportError.message("Choose a firmware folder. Symbolic links are not followed.")
        }
        progress("Finding IPSWs in \(directory.lastPathComponent)…")
        let candidates = try await FirmwareImportService.discover(in: [directory])
        var files: [FirmwareModelScanFile] = []
        var issues: [FirmwareModelScanIssue] = []
        var physicalFiles: Set<PhysicalFile> = []
        for file in candidates {
            try Task.checkCancellation()
            do {
                let before = try FirmwareImportFileIdentity.inspect(file)
                // Multiple hard links point at one archive. Reading it once is
                // sufficient, and the discovery order chooses a stable path.
                guard physicalFiles.insert(PhysicalFile(device: before.device, inode: before.inode)).inserted else { continue }
                guard before.size > 0 else {
                    throw FirmwareImportError.message("This IPSW is empty.")
                }
                progress("Reading \(file.lastPathComponent)…")
                let manifest = try FirmwareImportService.parseManifest(try await readManifest(file))
                try Task.checkCancellation()
                guard try FirmwareImportFileIdentity.inspect(file) == before else {
                    throw FirmwareImportError.message("This IPSW changed while it was scanned. Try again after it finishes downloading.")
                }
                files.append(FirmwareModelScanFile(fileURL: file, version: manifest.version,
                    build: manifest.build, modelIdentifiers: manifest.identifiers))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                issues.append(FirmwareModelScanIssue(fileURL: file, message: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        return FirmwareModelScanReport(files: files, issues: issues)
    }

    private struct PhysicalFile: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}

/// Limits follow suggestions and submitted selections to identified models in
/// the current catalog. Reviewing a suggestion never automatically follows it.
public enum FirmwareFollowSuggestionPolicy {
    public static func eligibleDevices(report: FirmwareModelScanReport, catalog: [DeviceFirmware],
                                       followedIDs: Set<String>, reviewedIDs: Set<String> = []) -> [DeviceFirmware] {
        let eligibleIDs = report.modelIdentifiers.subtracting(followedIDs).subtracting(reviewedIDs)
        var seen: Set<String> = []
        let devices = catalog.filter { eligibleIDs.contains($0.id) && seen.insert($0.id).inserted }
        return DeviceSorter.sort(devices, order: .newest, followedIDs: [])
    }

    public static func selectedIDs(_ selected: Set<String>, eligibleDevices: [DeviceFirmware]) -> Set<String> {
        selected.intersection(eligibleDevices.map(\.id))
    }
}
