import Foundation
import CryptoKit
import Darwin

/// Evidence from a complete checksum read. Only the verifier can create it;
/// registration rechecks the file's identity before saving the queue entry.
public struct VerifiedFirmwareImport: Sendable {
    public let fileURL: URL
    public let version: String
    public let build: String
    public let modelIdentifiers: [String]
    public let name: String
    public let bytes: Int64
    public let sha1: String
    public let downloadURL: URL
    public let warnings: [String]
    let identity: FirmwareImportFileIdentity
}

public enum FirmwareImportRegistrationResult: Equatable, Sendable {
    case imported(String)
    case alreadyAvailable(String)
    case busy(String)
}

public enum FirmwareImportError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// Identifies existing files in place. It reads metadata and the local archive;
/// it never downloads an IPSW, extracts its payload, or changes the source file.
public struct FirmwareImportService: Sendable {
    private let readManifest: @Sendable (URL) async throws -> Data
    private let fetchHistory: @Sendable (String) async throws -> FirmwareHistory

    public init() {
        readManifest = { try await ManifestReader.read($0) }
        fetchHistory = { try await FirmwareHistoryService().fetch(deviceIdentifier: $0) }
    }

    init(readManifest: @escaping @Sendable (URL) async throws -> Data,
         fetchHistory: @escaping @Sendable (String) async throws -> FirmwareHistory) {
        self.readManifest = readManifest
        self.fetchHistory = fetchHistory
    }

    init(fetchHistory: @escaping @Sendable (String) async throws -> FirmwareHistory) {
        readManifest = { try await ManifestReader.read($0) }
        self.fetchHistory = fetchHistory
    }

    /// Only explicitly selected folders are searched. Symbolic links, hidden
    /// files and packages are excluded, and traversal has a fixed work limit.
    public static func discover(in selections: [URL]) async throws -> [URL] {
        let task = Task.detached(priority: .utility) { try discoverFiles(in: selections) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func verify(file: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> VerifiedFirmwareImport {
        try Task.checkCancellation()
        guard file.isFileURL, file.pathExtension.lowercased() == "ipsw" else {
            throw FirmwareImportError.message("Choose an .ipsw file or a folder containing IPSWs.")
        }
        let file = file.standardizedFileURL
        let before = try FirmwareImportFileIdentity.inspect(file)
        guard before.size > 0 else { throw FirmwareImportError.message("This IPSW is empty.") }
        progress("Reading \(file.lastPathComponent)…")
        let manifest = try Self.parseManifest(try await readManifest(file))
        try Task.checkCancellation()
        var match: FirmwareRelease?
        var names: [String] = []
        var warnings: [String] = []
        for identifier in manifest.identifiers {
            try Task.checkCancellation()
            progress("Checking firmware metadata for \(identifier)…")
            let history: FirmwareHistory
            do { history = try await fetchHistory(identifier) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                warnings.append("Metadata for \(identifier) was unavailable; it remains linked to this file for cleanup checks.")
                continue
            }
            guard history.deviceIdentifier == identifier else {
                throw FirmwareImportError.message("Firmware history returned a different model. The file was not imported.")
            }
            let candidates = history.releases.filter { $0.version == manifest.version && $0.build == manifest.build }
            var found = false
            for release in candidates {
                guard let url = release.downloadURL, AppleDownloadPolicy.permits(url),
                      url.pathExtension.lowercased() == "ipsw", let checksum = release.sha1,
                      let size = release.fileSize, size > 0 else { continue }
                if let previous = match {
                    guard previous.fileSize == size, previous.sha1 == checksum,
                          previous.downloadURL.map(DownloadManager.identifier(for:)) == DownloadManager.identifier(for: url) else {
                        throw FirmwareImportError.message("The matching firmware records disagree about this archive. It was not imported.")
                    }
                } else { match = release }
                found = true
            }
            if found { names.append(history.deviceName) }
            else { warnings.append("No complete metadata was available for \(identifier); it remains linked to this file for cleanup checks.") }
        }
        guard let match, let url = match.downloadURL, let sha1 = match.sha1, let expected = match.fileSize else {
            throw FirmwareImportError.message("No matching Apple firmware record with a size and checksum was found. The file was left untouched.")
        }
        guard expected == before.size else {
            throw FirmwareImportError.message("The IPSW size does not match its firmware metadata. The file was not imported.")
        }
        guard try FirmwareImportFileIdentity.inspect(file) == before else {
            throw FirmwareImportError.message("The IPSW changed while its metadata was checked. Try importing it again when it is no longer being written.")
        }
        progress("Verifying \(file.lastPathComponent)…")
        let check = Task.detached(priority: .utility) {
            try Self.verifyChecksum(file: file, identity: before, expected: sha1)
        }
        try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
        try Task.checkCancellation()
        let uniqueNames = Array(Set(names)).sorted()
        let name = uniqueNames.count == 1 ? uniqueNames[0] : "\(manifest.identifiers.count) iPhone / iPad models"
        return VerifiedFirmwareImport(fileURL: file, version: manifest.version, build: manifest.build,
            modelIdentifiers: manifest.identifiers, name: name, bytes: expected, sha1: sha1,
            downloadURL: url, warnings: warnings, identity: before)
    }

    static func parseManifest(_ data: Data) throws -> (version: String, build: String, identifiers: [String]) {
        guard data.count <= ManifestReader.maximumBytes,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let version = plist["ProductVersion"] as? String,
              version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}\z"#, options: .regularExpression) != nil,
              let build = plist["ProductBuildVersion"] as? String,
              build.range(of: #"^[A-Za-z0-9]{1,40}\z"#, options: .regularExpression) != nil,
              let products = plist["SupportedProductTypes"] as? [String], products.count <= 256 else {
            throw FirmwareImportError.message("The IPSW does not contain a supported BuildManifest.plist.")
        }
        let identifiers = Array(Set(products.filter {
            $0.range(of: #"^(iPhone|iPad)[0-9]+,[0-9]+\z"#, options: .regularExpression) != nil
        })).sorted()
        guard !identifiers.isEmpty else { throw FirmwareImportError.message("This IPSW does not support an iPhone or iPad.") }
        return (version, build, identifiers)
    }

    private static func verifyChecksum(file: URL, identity: FirmwareImportFileIdentity, expected: String) throws {
        try Task.checkCancellation()
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard try FirmwareImportFileIdentity.inspect(descriptor) == identity else {
            throw FirmwareImportError.message("The IPSW changed before verification. It was not imported.")
        }
        var hasher = Insecure.SHA1()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            if count == 0, chunk.prefix(4) != Data([0x50, 0x4b, 0x03, 0x04]) {
                throw FirmwareImportError.message("This file is not an IPSW ZIP archive.")
            }
            count += Int64(chunk.count)
            guard count <= identity.size else { throw FirmwareImportError.message("The IPSW grew during verification. It was not imported.") }
            hasher.update(data: chunk)
        }
        try Task.checkCancellation()
        guard count == identity.size, try FirmwareImportFileIdentity.inspect(descriptor) == identity,
              try FirmwareImportFileIdentity.inspect(file) == identity else {
            throw FirmwareImportError.message("The IPSW changed during verification. It was not imported.")
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw FirmwareImportError.message("The IPSW checksum does not match its firmware metadata. The file was not imported.")
        }
    }

    private static func discoverFiles(in selections: [URL]) throws -> [URL] {
        var files: Set<URL> = []
        var folders: Set<String> = []
        var pending = selections.filter(\.isFileURL).map(\.standardizedFileURL)
        var visited = 0
        let manager = FileManager.default
        while let url = pending.popLast() {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 20_000 else {
                throw FirmwareImportError.message("This selection is too large. Choose a smaller folder with fewer than 5,000 IPSWs and 20,000 entries.")
            }
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let kind = attributes.st_mode & mode_t(S_IFMT)
            // lstat examines the selected entry itself, without following a
            // link. Each real directory is visited at most once.
            if kind == mode_t(S_IFLNK) { continue }
            if kind == mode_t(S_IFDIR) {
                guard folders.insert(url.path).inserted else { continue }
                let values = try url.resourceValues(forKeys: [.isPackageKey])
                guard values.isPackage != true else { continue }
                let contents = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isPackageKey], options: [.skipsHiddenFiles])
                guard visited + pending.count + contents.count <= 20_000 else {
                    throw FirmwareImportError.message("This selection is too large. Choose a smaller folder with fewer than 20,000 entries.")
                }
                pending.append(contentsOf: contents)
            } else if kind == mode_t(S_IFREG), url.pathExtension.lowercased() == "ipsw" {
                files.insert(url.standardizedFileURL)
                guard files.count <= 5_000 else {
                    throw FirmwareImportError.message("This selection contains more than 5,000 IPSWs. Choose a smaller folder.")
                }
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

}

struct FirmwareImportFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func inspect(_ file: URL) throws -> Self {
        var value = stat()
        guard lstat(file.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try make(value)
    }
    static func inspect(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try make(value)
    }
    private static func make(_ value: stat) throws -> Self {
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FirmwareImportError.message("Only regular IPSW files can be imported. Symbolic links are not followed.")
        }
        return Self(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

/// A bounded stdout pipe avoids writing untrusted archive entries to disk.
/// Cancellation and the timeout kill only the child process this reader owns.
final class ManifestReader: @unchecked Sendable {
    static let maximumBytes = 8 * 1_024 * 1_024
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    static func read(_ file: URL) async throws -> Data {
        let reader = ManifestReader()
        let task = Task.detached(priority: .utility) { try reader.extract(file) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel()
            reader.stop(timeout: false)
        }
    }

    private func stop(timeout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if timeout { timedOut = true } else { cancelled = true }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func extract(_ file: URL) throws -> Data {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        child.arguments = ["-p", file.path, "BuildManifest.plist"]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in self?.stop(timeout: true) }
        timer.resume()
        defer {
            timer.cancel()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= Self.maximumBytes else {
                throw FirmwareImportError.message("The IPSW manifest is larger than the supported limit.")
            }
            data.append(chunk)
        }
        child.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw FirmwareImportError.message("Reading the IPSW manifest timed out.") }
        guard child.terminationStatus == 0, !data.isEmpty else {
            throw FirmwareImportError.message("The IPSW could not be read or has no BuildManifest.plist.")
        }
        return data
    }
}
