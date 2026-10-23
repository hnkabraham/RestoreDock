import Foundation
import Combine
import CryptoKit
import Darwin

public enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, paused, verifying, ready, failed
}

public enum CompletedDownloadRemovalResult: Equatable, Sendable {
    case removed
    /// Keep the entry: an external volume may simply be disconnected.
    case missing
    case notEligible
    case failed(String)
}

public struct DownloadItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var modelIdentifiers: [String]
    public var version: String
    public var build: String
    public var url: URL
    public var filename: String
    public var expectedBytes: Int64?
    public var downloadedBytes: Int64
    public var status: DownloadStatus
    public var errorMessage: String?
    public var completedAt: Date?
    public var sha1: String?
    /// These paths stay attached to this download when the user changes folders.
    public var destinationPath: String?
    public var localPath: String?
    public var stagingPath: String?
    public var automaticRetryCount: Int?
    public var nextRetryAt: Date?
    public var automaticRetryAllowed: Bool?
    /// Imported files remain in their original location and are protected from
    /// automatic cleanup unless the user explicitly opts in for this import.
    public var importedAt: Date?
    public var importedCleanupAllowed: Bool?

    public var allowsAutomaticCleanup: Bool {
        importedAt == nil || importedCleanupAllowed == true
    }

    public var progress: Double {
        guard let expectedBytes, expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(expectedBytes)))
    }

    public init(id: String, name: String, modelIdentifiers: [String], version: String,
                build: String, url: URL, filename: String, expectedBytes: Int64? = nil,
                downloadedBytes: Int64 = 0, status: DownloadStatus = .queued,
                errorMessage: String? = nil, completedAt: Date? = nil, sha1: String? = nil,
                destinationPath: String? = nil, localPath: String? = nil, stagingPath: String? = nil,
                importedAt: Date? = nil, importedCleanupAllowed: Bool? = nil) {
        self.id = id; self.name = name; self.modelIdentifiers = modelIdentifiers
        self.version = version; self.build = build; self.url = url; self.filename = filename
        self.expectedBytes = expectedBytes; self.downloadedBytes = downloadedBytes
        self.status = status; self.errorMessage = errorMessage; self.completedAt = completedAt
        self.sha1 = sha1; self.destinationPath = destinationPath; self.localPath = localPath
        self.stagingPath = stagingPath
        self.importedAt = importedAt; self.importedCleanupAllowed = importedCleanupAllowed
    }
}

/// A single-transfer queue. Only validated firmware is renamed to an .ipsw file.
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []
    @Published public private(set) var isPaused = false
    @Published public private(set) var persistenceError: String?

    public var destinationDirectory: URL { didSet { persist() } }
    public var reserveBytes: Int64 = 20 * 1_024 * 1_024 * 1_024 {
        didSet { if reserveBytes < 0 { reserveBytes = 0 }; persist() }
    }

    private struct Snapshot: Codable {
        var version = 1
        var items: [DownloadItem]
        var isPaused: Bool
        var destinationDirectory: URL
        var reserveBytes: Int64
        var automaticallyRemovedIDs: Set<String>?
    }
    private enum Cancellation {
        case pause, shutdown, remove, failure(String)
    }

    private let stateDirectory: URL
    private let resumeDirectory: URL
    private var activeID: String?
    private var activeToken: UUID?
    private var activeTask: URLSessionDownloadTask?
    private var activeUsesResumeData = false
    private var verification: Task<Void, Error>?
    private var cancellation: Cancellation?
    private var shuttingDown = false
    private var lastPersist = Date.distantPast
    private var lastCapacityCheck = Date.distantPast
    private var retryWake: Task<Void, Never>?
    private var queueLoadError: String?
    private var persistenceBlocked = false
    private var delegate: FirmwareDownloadDelegate?
    private var sessionStorage: URLSession?
    private var automaticallyRemovedIDs: Set<String> = []
    private var cleanupIDs: Set<String> = []
    // Internal seam for isolated filesystem tests. Production permanently
    // removes only the exact completed file validated by removeUnsignedDownload.
    var removeCompletedFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    public init(stateDirectory: URL, destinationDirectory: URL) {
        self.stateDirectory = stateDirectory
        self.resumeDirectory = stateDirectory.appendingPathComponent("Resume", isDirectory: true)
        self.destinationDirectory = destinationDirectory
        do {
            try FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
            let stateURL = stateDirectory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: stateURL))
                guard snapshot.version == 1 else { throw DownloadError.message("The download queue uses an unsupported format.") }
                self.destinationDirectory = snapshot.destinationDirectory
                self.reserveBytes = max(0, snapshot.reserveBytes)
                self.isPaused = snapshot.isPaused
                self.automaticallyRemovedIDs = snapshot.automaticallyRemovedIDs ?? []
                self.items = snapshot.items.map { item in
                    var item = item
                    if item.status == .downloading || item.status == .paused || item.status == .queued {
                        item.status = snapshot.isPaused ? .paused : .queued
                    }
                    if item.status == .verifying,
                       !(item.stagingPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                        item.status = snapshot.isPaused ? .paused : .queued
                    }
                    if item.status == .ready,
                       !(item.localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                        item.status = .failed
                        item.errorMessage = "The saved firmware is missing. Reconnect its drive or retry the download."
                    }
                    return item
                }
            }
        } catch {
            let message = "Could not load the saved queue: \(error.localizedDescription)"
            let original = stateDirectory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: original.path) {
                let backup = stateDirectory.appendingPathComponent("downloads-recovery-\(UUID().uuidString).json")
                do {
                    try FileManager.default.copyItem(at: original, to: backup)
                    queueLoadError = message + " The original was preserved as \(backup.lastPathComponent)."
                } catch {
                    persistenceBlocked = true
                    queueLoadError = message + " The original could not be backed up, so queue writes are disabled."
                }
            } else { queueLoadError = message }
            persistenceError = queueLoadError
        }
        // Yield so the app can apply its settings before the first transfer begins.
        Task { @MainActor [weak self] in self?.startNext() }
    }

    public func enqueue(_ firmwares: [DeviceFirmware], automatically: Bool = false) {
        for firmware in firmwares {
            let id = Self.identifier(for: firmware.downloadURL)
            if automatically && automaticallyRemovedIDs.contains(id) { continue }
            if !automatically { automaticallyRemovedIDs.remove(id) }
            if let index = items.firstIndex(where: { $0.id == id }) {
                let gainedChecksum = items[index].sha1?.isEmpty != false && firmware.sha1?.isEmpty == false
                if activeID != id {
                    if let checksum = firmware.sha1, !checksum.isEmpty { items[index].sha1 = checksum }
                    if let size = firmware.fileSize, size > 0 { items[index].expectedBytes = size }
                }
                if !items[index].modelIdentifiers.contains(firmware.id) {
                    items[index].modelIdentifiers.append(firmware.id)
                    items[index].modelIdentifiers.sort()
                }
                let missingReadyFile = (items[index].status == .ready || items[index].completedAt != nil)
                    && !(items[index].localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
                if activeID != id && (missingReadyFile || (items[index].status == .failed && (items[index].automaticRetryAllowed == true || gainedChecksum))) {
                    items[index].status = isPaused ? .paused : .queued
                    items[index].errorMessage = nil
                    items[index].automaticRetryCount = 0
                    items[index].nextRetryAt = nil
                    if missingReadyFile {
                        items[index].localPath = nil
                        items[index].completedAt = nil
                        items[index].downloadedBytes = 0
                    }
                }
                continue
            }
            let allowed = AppleDownloadPolicy.permits(firmware.downloadURL)
            items.append(DownloadItem(
                id: id, name: firmware.name, modelIdentifiers: [firmware.id],
                version: firmware.version, build: firmware.build, url: firmware.downloadURL,
                filename: Self.safeFilename(for: firmware.downloadURL, fallback: id),
                expectedBytes: firmware.fileSize.flatMap { $0 > 0 ? $0 : nil },
                status: allowed ? (isPaused ? .paused : .queued) : .failed,
                errorMessage: allowed ? nil : "This firmware URL is not an approved Apple HTTPS download.",
                sha1: firmware.sha1))
        }
        persist()
        startNext()
    }

    public func pause() {
        isPaused = true
        for index in items.indices where items[index].status == .queued { items[index].status = .paused }
        persist()
        if activeTask != nil { cancelActive(.pause) }
    }

    public func resume() {
        shuttingDown = false
        isPaused = false
        for index in items.indices where items[index].status == .paused { items[index].status = .queued }
        persist()
        startNext()
    }

    public func retry(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .failed else { return }
        items[index].status = isPaused ? .paused : .queued
        items[index].errorMessage = nil
        items[index].automaticRetryCount = 0
        items[index].nextRetryAt = nil
        if items[index].completedAt != nil && localURL(for: items[index]) == nil {
            items[index].localPath = nil
            items[index].completedAt = nil
        }
        persist()
        startNext()
    }

    /// Removing a queue entry leaves downloaded files alone unless explicitly requested.
    /// Explicit deletion uses the Trash, and keeps the entry if the move fails.
    public func remove(_ id: String, deleteFile: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if deleteFile, let path = item.localPath, FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            catch {
                items[index].errorMessage = "Could not move the firmware to Trash: \(error.localizedDescription)"
                persist()
                return
            }
        }
        if activeID == id {
            if activeTask != nil { cancelActive(.remove) }
            else {
                verification?.cancel()
                clearActive()
            }
        }
        if let path = item.stagingPath { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: resumeURL(for: id))
        items.removeAll { $0.id == id }
        persist()
        startNext()
    }

    public func localURL(for item: DownloadItem) -> URL? {
        guard item.status == .ready, let path = item.localPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Registers an already verified archive in place. Saving the proposed
    /// snapshot precedes publishing any queue changes, and no transfer starts.
    public func registerImport(_ verified: VerifiedFirmwareImport,
                               allowAutomaticCleanup: Bool = false) throws -> FirmwareImportRegistrationResult {
        try Task.checkCancellation()
        let id = Self.identifier(for: verified.downloadURL)
        guard !shuttingDown else { throw FirmwareImportError.message("The app is closing. Import this file again after reopening it.") }
        guard activeID != id, !cleanupIDs.contains(id) else { return .busy(id) }
        guard try FirmwareImportFileIdentity.inspect(verified.fileURL) == verified.identity else {
            throw FirmwareImportError.message("The IPSW changed after verification. It was not imported.")
        }
        if let existing = items.first(where: { $0.id == id }), existing.status == .verifying {
            return .busy(id)
        }
        // Keep an existing usable ready entry, including its chosen cleanup
        // permission. A second import must not silently replace its location.
        for index in items.indices {
            let existing = items[index]
            guard existing.status == .ready, let path = existing.localPath,
                  let identity = try? FirmwareImportFileIdentity.inspect(URL(fileURLWithPath: path)),
                  identity.size == existing.downloadedBytes, identity.size > 0 else { continue }
            if existing.id == id || (identity.device == verified.identity.device && identity.inode == verified.identity.inode) {
                // A download originally queued for one model may support many
                // others. Retain the manifest's full set for later cleanup.
                let identifiers = Array(Set(existing.modelIdentifiers + verified.modelIdentifiers)).sorted()
                if identifiers != existing.modelIdentifiers {
                    var proposed = items
                    proposed[index].modelIdentifiers = identifiers
                    guard persist(snapshotItems: proposed) else {
                        throw FirmwareImportError.message("The firmware's supported models could not be saved. The existing library entry was left unchanged.")
                    }
                    items = proposed
                }
                return .alreadyAvailable(existing.id)
            }
        }
        let now = Date()
        let item = DownloadItem(id: id, name: verified.name, modelIdentifiers: verified.modelIdentifiers,
            version: verified.version, build: verified.build, url: verified.downloadURL,
            filename: verified.fileURL.lastPathComponent, expectedBytes: verified.bytes,
            downloadedBytes: verified.bytes, status: .ready, completedAt: now, sha1: verified.sha1,
            destinationPath: verified.fileURL.deletingLastPathComponent().path, localPath: verified.fileURL.path,
            importedAt: now, importedCleanupAllowed: allowAutomaticCleanup)
        var proposed = items
        if let index = proposed.firstIndex(where: { $0.id == id }) { proposed[index] = item }
        else { proposed.append(item) }
        var removedIDs = automaticallyRemovedIDs
        removedIDs.remove(id)
        guard persist(snapshotItems: proposed, removedIDs: removedIDs) else {
            throw FirmwareImportError.message("The imported firmware could not be saved to the library. Your file and existing queue were left unchanged.")
        }
        items = proposed
        automaticallyRemovedIDs = removedIDs
        try? FileManager.default.removeItem(at: resumeURL(for: id))
        return .imported(id)
    }

    /// Permanently removes one validated, completed file. The caller must first
    /// confirm that the exact release is unsigned for every associated model.
    /// Pass the earliest expiry of those signing checks; it is enforced again
    /// immediately before removal, after the potentially lengthy checksum read.
    /// No folder enumeration is performed. Missing or failed files keep their
    /// queue entries, and only successful removal suppresses future auto-enqueue.
    public func removeUnsignedDownload(_ id: String, signingApprovalExpiresAt: Date) async -> CompletedDownloadRemovalResult {
        guard signingApprovalExpiresAt > Date(), !Task.isCancelled, activeID != id, !cleanupIDs.contains(id),
              let item = items.first(where: { $0.id == id }),
              let file = Self.managedCompletedURL(for: item) else { return .notEligible }
        cleanupIDs.insert(id)
        var insertedTombstone = false
        var removedFile = false
        defer {
            cleanupIDs.remove(id)
            if insertedTombstone && !removedFile {
                automaticallyRemovedIDs.remove(id)
                persist()
            }
        }
        do {
            let before: CompletedFileIdentity
            switch try Self.inspectCompletedFile(at: file) {
            case .missing: return .missing
            case .notRegular: return .notEligible
            case .regular(let identity): before = identity
            }
            guard !hasOtherReference(to: file, identity: before, excluding: id) else { return .notEligible }
            guard before.size == item.downloadedBytes else {
                throw DownloadError.message("The completed firmware's file size has changed. It was left untouched.")
            }
            // Rehash off the main actor. A forged or stale queue path cannot
            // turn an unrelated file into an eligible firmware cleanup target.
            let check = Task.detached(priority: .utility) {
                try Self.validate(file: file, expectedBytes: item.downloadedBytes, sha1: item.sha1)
            }
            try await withTaskCancellationHandler {
                try await check.value
            } onCancel: {
                check.cancel()
            }
            guard !Task.isCancelled, activeID != id,
                  let index = items.firstIndex(where: { $0.id == id }), items[index] == item,
                  Self.managedCompletedURL(for: items[index]) == file,
                  !hasOtherReference(to: file, identity: before, excluding: id) else { return .notEligible }
            // Commit suppression while retaining the ready entry. If the app
            // exits after removing the file, its next launch still knows not
            // to download the unsigned firmware again. Never remove the file
            // if this prerequisite queue write cannot be completed.
            insertedTombstone = automaticallyRemovedIDs.insert(id).inserted
            guard persist() else {
                throw DownloadError.message("The cleanup decision could not be saved. The firmware was left untouched.")
            }
            guard !Task.isCancelled else { return .notEligible }
            switch try Self.inspectCompletedFile(at: file) {
            case .missing: return .missing
            case .notRegular: return .notEligible
            case .regular(let after):
                guard after == before else {
                    throw DownloadError.message("The completed firmware changed during verification. It was left untouched.")
                }
            }
            // There is deliberately no suspension between the final identity
            // check and removal, so other app actions cannot replace this item.
            // Rehashing a large IPSW on a slow drive may outlive the signing
            // check, so its approval must still be fresh at the actual removal.
            guard signingApprovalExpiresAt > Date(), !Task.isCancelled else { return .notEligible }
            try removeCompletedFile(file)
            removedFile = true
            items.remove(at: index)
            try? FileManager.default.removeItem(at: resumeURL(for: id))
            persist()
            return .removed
        } catch is CancellationError {
            return .notEligible
        } catch {
            guard !Task.isCancelled else { return .notEligible }
            let message = "Could not remove unsigned firmware: \(error.localizedDescription)"
            if let index = items.firstIndex(where: { $0.id == id }), items[index].status == .ready {
                items[index].errorMessage = message
                persist()
            }
            return .failed(message)
        }
    }

    /// A queue record is eligible only for the exact IPSW filename we produced
    /// in its recorded destination, including our non-overwriting collision names.
    nonisolated static func managedCompletedURL(for item: DownloadItem) -> URL? {
        guard item.allowsAutomaticCleanup, item.status == .ready, item.completedAt != nil, item.downloadedBytes > 0,
              item.stagingPath == nil, item.id == identifier(for: item.url),
              AppleDownloadPolicy.permits(item.url), let checksum = item.sha1?.trimmingCharacters(in: .whitespacesAndNewlines),
              (checksum.utf8.count == 40 && checksum.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }))
                || Data(base64Encoded: checksum)?.count == 20,
              let path = item.localPath, path.hasPrefix("/"),
              let destinationPath = item.destinationPath, destinationPath.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        guard file.path == file.standardizedFileURL.path,
              destination.path == destination.standardizedFileURL.path,
              file.lastPathComponent == item.filename, file.pathExtension.lowercased() == "ipsw",
              file.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL,
              file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
                == destination.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        let original = safeFilename(for: item.url, fallback: item.id)
        if item.importedAt == nil, item.filename != original {
            let stem = (original as NSString).deletingPathExtension
            let escapedStem = NSRegularExpression.escapedPattern(for: stem)
            let prefix = String(item.id.prefix(8))
            let pattern = "^\(escapedStem)(?:-\(prefix)(?:-(?:[2-9]|[1-9][0-9]{1,2}|1000))?)+\\.ipsw\\z"
            guard item.filename.range(of: pattern, options: .regularExpression) != nil else { return nil }
        }
        return file
    }

    private struct CompletedFileIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var createdSeconds: Int64
        var createdNanoseconds: Int64
    }

    private enum CompletedFileInspection {
        case missing, notRegular
        case regular(CompletedFileIdentity)
    }

    /// A separately tracked alias may carry different model or cleanup rules.
    /// Require one unambiguous library owner before deleting a physical file.
    private func hasOtherReference(to file: URL, identity: CompletedFileIdentity, excluding id: String) -> Bool {
        for other in items where other.id != id {
            guard let path = other.localPath else { continue }
            let url = URL(fileURLWithPath: path)
            if url.resolvingSymlinksInPath().standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL { return true }
            if case .regular(let otherIdentity) = try? Self.inspectCompletedFile(at: url),
               otherIdentity.device == identity.device && otherIdentity.inode == identity.inode { return true }
        }
        return false
    }

    nonisolated private static func inspectCompletedFile(at url: URL) throws -> CompletedFileInspection {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .notRegular }
        return .regular(CompletedFileIdentity(device: UInt64(truncatingIfNeeded: attributes.st_dev), inode: UInt64(attributes.st_ino),
            size: Int64(attributes.st_size), modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec), createdSeconds: Int64(attributes.st_birthtimespec.tv_sec),
            createdNanoseconds: Int64(attributes.st_birthtimespec.tv_nsec)))
    }

    /// The queue survives any exit. On graceful exit URLSession also gets a chance
    /// to save a partial transfer; after a force quit that transfer may restart.
    public func shutdown() {
        shuttingDown = true
        retryWake?.cancel()
        if activeTask != nil { cancelActive(.shutdown) }
        persist()
    }

    nonisolated public static func identifier(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        components?.fragment = nil
        if components?.port == 443 { components?.port = nil }
        let canonical = components?.string ?? url.absoluteString
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func safeFilename(for url: URL, fallback: String) -> String {
        let component = url.lastPathComponent
        let cleaned = component.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) { return "_" }
            return String(scalar)
        }.joined()
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Firmware-\(fallback.prefix(12)).ipsw" }
        return cleaned.lowercased().hasSuffix(".ipsw") ? cleaned : cleaned + ".ipsw"
    }

    private var session: URLSession {
        if let sessionStorage { return sessionStorage }
        let delegate = FirmwareDownloadDelegate()
        delegate.progress = { [weak self] token, bytes, expected in
            Task { @MainActor [weak self] in self?.receivedProgress(token: token, bytes: bytes, expected: expected) }
        }
        delegate.finished = { [weak self] token, result in
            Task { @MainActor [weak self] in self?.receivedFile(token: token, result: result) }
        }
        delegate.failed = { [weak self] token, error in
            Task { @MainActor [weak self] in self?.receivedFailure(token: token, error: error) }
        }
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "RestoreDock.downloads"
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        self.delegate = delegate
        self.sessionStorage = session
        return session
    }

    private func startNext() {
        guard activeID == nil, !isPaused, !shuttingDown else { return }
        guard let index = items.firstIndex(where: {
            ($0.status == .queued || $0.status == .verifying) && ($0.nextRetryAt ?? .distantPast) <= Date()
        }) else {
            scheduleRetryWake()
            return
        }
        var item = items[index]
        guard AppleDownloadPolicy.permits(item.url) else {
            fail(index: index, message: "This firmware URL is not an approved Apple HTTPS download.")
            scheduleNext()
            return
        }
        guard item.sha1?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            fail(index: index, message: "The firmware metadata did not provide a checksum for this firmware. It cannot be safely verified.")
            scheduleNext()
            return
        }
        let token = UUID()
        if item.status == .verifying, let stagingPath = item.stagingPath,
           FileManager.default.fileExists(atPath: stagingPath) {
            activeID = item.id; activeToken = token
            beginVerification(item: item, token: token, file: URL(fileURLWithPath: stagingPath))
            return
        }
        let destination = item.destinationPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? destinationDirectory
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let hasResumeData = FileManager.default.fileExists(atPath: resumeURL(for: item.id).path)
            try Self.requireTransferCapacity(destination: destination, expectedBytes: item.expectedBytes,
                                             downloadedBytes: hasResumeData ? item.downloadedBytes : 0, reserveBytes: reserveBytes)
            let staging = destination.appendingPathComponent(".restoredock-\(item.id.prefix(16))-\(UUID().uuidString).download")
            item.destinationPath = destination.path
            item.stagingPath = staging.path
            item.errorMessage = nil
            item.nextRetryAt = nil
            item.status = .downloading
            activeID = item.id; activeToken = token
            let session = self.session
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeURL(for: item.id)), !resumeData.isEmpty {
                activeUsesResumeData = true
                let resumed = session.downloadTask(withResumeData: resumeData)
                if let requestURL = resumed.originalRequest?.url, !AppleDownloadPolicy.permits(requestURL) {
                    resumed.cancel()
                    throw DownloadError.message("The saved transfer contains an unapproved download URL.")
                }
                task = resumed
            } else {
                item.downloadedBytes = 0
                task = session.downloadTask(with: item.url)
            }
            items[index] = item
            activeTask = task
            delegate?.register(task: task, token: token, staging: staging)
            persist()
            lastCapacityCheck = .distantPast
            task.resume()
        } catch {
            clearActive()
            fail(index: index, message: error.localizedDescription)
            scheduleNext()
        }
    }

    private func receivedProgress(token: UUID, bytes: Int64, expected: Int64) {
        guard token == activeToken, cancellation == nil,
              let index = items.firstIndex(where: { $0.id == activeID }), items[index].status == .downloading else { return }
        items[index].downloadedBytes = max(0, bytes)
        if items[index].expectedBytes == nil && expected > 0 { items[index].expectedBytes = expected }
        let now = Date()
        if now.timeIntervalSince(lastCapacityCheck) > 5,
           let destination = items[index].destinationPath,
           let total = items[index].expectedBytes {
            lastCapacityCheck = now
            do {
                try Self.requireTransferCapacity(destination: URL(fileURLWithPath: destination), expectedBytes: total,
                                                 downloadedBytes: bytes, reserveBytes: reserveBytes)
            } catch { cancelActive(.failure(error.localizedDescription)) }
        }
        if now.timeIntervalSince(lastPersist) > 3 { persist() }
    }

    private func receivedFile(token: UUID, result: Result<URL, Error>) {
        guard token == activeToken, cancellation == nil,
              let index = items.firstIndex(where: { $0.id == activeID }) else {
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        activeTask = nil
        switch result {
        case .success(let file):
            items[index].status = .verifying
            persist()
            beginVerification(item: items[index], token: token, file: file)
        case .failure(let error):
            fail(index: index, message: error.localizedDescription, retryable: Self.isTransient(error))
            clearActive()
            startNext()
        }
    }

    private func beginVerification(item: DownloadItem, token: UUID, file: URL) {
        let check = Task.detached(priority: .utility) {
            try Self.validate(file: file, expectedBytes: item.expectedBytes, sha1: item.sha1)
        }
        verification = check
        Task { @MainActor [weak self] in
            let result = await check.result
            guard let self, self.activeToken == token,
                  let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            do {
                try result.get()
                let folder = URL(fileURLWithPath: item.destinationPath ?? file.deletingLastPathComponent().path, isDirectory: true)
                let final = try Self.availableDestination(in: folder, filename: item.filename, id: item.id)
                // Staging and final paths share a volume: this rename is atomic and
                // FileManager refuses to replace an existing destination.
                try FileManager.default.moveItem(at: file, to: final)
                let size = (try? final.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                self.items[index].localPath = final.path
                self.items[index].filename = final.lastPathComponent
                self.items[index].stagingPath = nil
                self.items[index].downloadedBytes = size.map(Int64.init) ?? self.items[index].downloadedBytes
                self.items[index].status = .ready
                self.items[index].completedAt = Date()
                self.items[index].errorMessage = nil
                self.items[index].nextRetryAt = nil
                self.items[index].automaticRetryAllowed = false
                try? FileManager.default.removeItem(at: self.resumeURL(for: item.id))
                self.persist()
            } catch {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: self.resumeURL(for: item.id))
                self.items[index].stagingPath = nil
                self.items[index].downloadedBytes = 0
                self.fail(index: index, message: error.localizedDescription)
            }
            self.clearActive()
            self.startNext()
        }
    }

    private func receivedFailure(token: UUID, error: Error) {
        guard token == activeToken,
              let index = items.firstIndex(where: { $0.id == activeID }) else { return }
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(resumeData, id: items[index].id)
        }
        // cancel(byProducingResumeData:) owns cancellation completion and can
        // arrive after this delegate callback.
        guard cancellation == nil else { return }
        // Invalid or expired URLSession resume data commonly reports .unknown
        // or .cannotOpenFile. Try one clean request; ordinary network failures
        // remain visible to the user with their resumable data intact.
        if activeUsesResumeData && nsError.domain == NSURLErrorDomain
            && [NSURLErrorUnknown, NSURLErrorCannotOpenFile].contains(nsError.code) {
            try? FileManager.default.removeItem(at: resumeURL(for: items[index].id))
            items[index].downloadedBytes = 0
            items[index].status = .queued
            items[index].errorMessage = nil
            clearActive()
            persist()
            startNext()
            return
        }
        fail(index: index, message: error.localizedDescription, retryable: Self.isTransient(error))
        clearActive()
        startNext()
    }

    private func cancelActive(_ reason: Cancellation) {
        guard let task = activeTask, let id = activeID, let token = activeToken else { return }
        if cancellation != nil {
            if case .remove = reason { cancellation = reason }
            return
        }
        cancellation = reason
        task.cancel { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.activeToken == token else { return }
                if let index = self.items.firstIndex(where: { $0.id == id }) {
                    if let data { self.saveResumeData(data, id: id) }
                    switch self.cancellation {
                    case .failure(let message):
                        self.items[index].status = .failed
                        self.items[index].errorMessage = message
                    case .remove: break
                    default:
                        self.items[index].status = self.isPaused ? .paused : .queued
                    }
                }
                self.clearActive()
                self.persist()
                self.startNext()
            }
        }
    }

    private func clearActive() {
        activeID = nil; activeToken = nil; activeTask = nil
        activeUsesResumeData = false
        verification = nil; cancellation = nil
    }

    private func scheduleNext() { Task { @MainActor [weak self] in self?.startNext() } }

    private func fail(index: Int, message: String, retryable: Bool = false) {
        items[index].status = .failed
        items[index].errorMessage = message
        items[index].automaticRetryAllowed = retryable
        items[index].nextRetryAt = nil
        let attempts = items[index].automaticRetryCount ?? 0
        if retryable && attempts < 3 {
            let delay: TimeInterval = [30, 120, 600][attempts]
            items[index].automaticRetryCount = attempts + 1
            items[index].nextRetryAt = Date().addingTimeInterval(delay)
            items[index].status = isPaused ? .paused : .queued
            items[index].errorMessage = message + " Automatic retry \(attempts + 1) of 3 is scheduled."
        }
        persist()
    }

    private func scheduleRetryWake() {
        retryWake?.cancel()
        guard let date = items.filter({ $0.status == .queued }).compactMap(\.nextRetryAt).min() else { return }
        let interval = min(86_400, max(0.05, date.timeIntervalSinceNow))
        retryWake = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            catch { return }
            self?.startNext()
        }
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let downloadError = error as? DownloadError, case .http(let status) = downloadError {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet].contains(error.code)
    }

    private func resumeURL(for id: String) -> URL { resumeDirectory.appendingPathComponent(id + ".resume") }

    private func saveResumeData(_ data: Data, id: String) {
        do { try data.write(to: resumeURL(for: id), options: .atomic) }
        catch { persistenceError = "Could not save the partial transfer: \(error.localizedDescription)" }
    }

    @discardableResult
    private func persist(snapshotItems: [DownloadItem]? = nil, removedIDs: Set<String>? = nil) -> Bool {
        guard !persistenceBlocked else { return false }
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = Snapshot(items: snapshotItems ?? items, isPaused: isPaused, destinationDirectory: destinationDirectory,
                                    reserveBytes: reserveBytes, automaticallyRemovedIDs: removedIDs ?? automaticallyRemovedIDs)
            try encoder.encode(snapshot).write(to: stateDirectory.appendingPathComponent("downloads.json"), options: .atomic)
            lastPersist = Date()
            persistenceError = queueLoadError
            return true
        } catch {
            persistenceError = "Could not save the download queue: \(error.localizedDescription)"
            return false
        }
    }

    /// URLSession first writes into temporary storage. A different destination
    /// volume must hold the entire file while the temporary copy still exists.
    nonisolated static func requireTransferCapacity(destination: URL, expectedBytes: Int64?, downloadedBytes: Int64, reserveBytes: Int64) throws {
        let temporary = FileManager.default.temporaryDirectory
        let tempVolume = try temporary.resourceValues(forKeys: [.volumeURLKey]).volume
        let destinationVolume = try destination.resourceValues(forKeys: [.volumeURLKey]).volume
        let sameVolume = tempVolume != nil && tempVolume == destinationVolume
        let fullSize = expectedBytes ?? 15 * 1_024 * 1_024 * 1_024
        let remaining = max(0, fullSize - max(0, downloadedBytes))
        do { try requireCapacity(at: temporary, remainingBytes: remaining, reserveBytes: reserveBytes) }
        catch { throw DownloadError.message("Temporary download storage: \(error.localizedDescription)") }
        try requireCapacity(at: destination, remainingBytes: sameVolume ? remaining : fullSize, reserveBytes: reserveBytes)
    }

    nonisolated static func requireCapacity(at folder: URL, remainingBytes: Int64, reserveBytes: Int64) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw DownloadError.message("Available storage could not be checked for this folder.")
        }
        let (needed, overflow) = max(0, remainingBytes).addingReportingOverflow(max(0, reserveBytes))
        guard !overflow, available >= needed else {
            let amount = ByteCountFormatter.string(fromByteCount: overflow ? Int64.max : needed, countStyle: .file)
            throw DownloadError.message("Not enough storage. This transfer needs \(amount) available, including the free-space reserve.")
        }
    }

    nonisolated static func availableDestination(in folder: URL, filename: String, id: String) throws -> URL {
        let original = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: original.path) { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        for number in 1...1_000 {
            let suffix = number == 1 ? String(id.prefix(8)) : "\(id.prefix(8))-\(number)"
            let alternative = folder.appendingPathComponent("\(stem)-\(suffix).ipsw")
            if !FileManager.default.fileExists(atPath: alternative.path) { return alternative }
        }
        throw DownloadError.message("Could not choose a filename without replacing an existing file.")
    }

    nonisolated static func validate(file: URL, expectedBytes: Int64?, sha1: String?) throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw DownloadError.message("The downloaded firmware is empty.") }
        if let expectedBytes, size != expectedBytes {
            throw DownloadError.message("The download is incomplete: expected \(expectedBytes) bytes, received \(size). Retry to download it again.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // IPSW is a ZIP container. Reject a successful HTTP response carrying an
        // HTML error page even when the catalog has no checksum or file size.
        let signature = try handle.read(upToCount: 4) ?? Data()
        guard signature == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw DownloadError.message("The server response is not an IPSW archive. Retry the download.")
        }
        guard let sha1, !sha1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DownloadError.message("The firmware metadata did not provide a checksum for this firmware. It cannot be safely verified.")
        }
        let expected = sha1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedHex: String
        if expected.count == 40 && expected.allSatisfy({ $0.isHexDigit }) {
            expectedHex = expected
        } else if let data = Data(base64Encoded: sha1.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 20 {
            expectedHex = data.map { String(format: "%02x", $0) }.joined()
        } else { throw DownloadError.message("The catalog supplied an invalid SHA-1 checksum.") }
        try handle.seek(toOffset: 0)
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHex else {
            throw DownloadError.message("The firmware checksum does not match its metadata.")
        }
    }
}

private enum DownloadError: LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .http(let status): return "Apple's download server returned HTTP \(status). Retry later."
        }
    }
}

/// URLSession calls delegates on a private serial queue. The temporary file must
/// be moved before its callback returns; all UI mutations are forwarded to MainActor.
private final class FirmwareDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Transfer {
        var token: UUID
        var staging: URL
        var lastProgress = Date.distantPast
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    var progress: ((UUID, Int64, Int64) -> Void)?
    var finished: ((UUID, Result<URL, Error>) -> Void)?
    var failed: ((UUID, Error) -> Void)?

    func register(task: URLSessionTask, token: UUID, staging: URL) {
        lock.lock(); defer { lock.unlock() }
        transfers[task.taskIdentifier] = Transfer(token: token, staging: staging)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        guard var transfer = transfers[downloadTask.taskIdentifier] else { lock.unlock(); return }
        let now = Date()
        guard now.timeIntervalSince(transfer.lastProgress) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { lock.unlock(); return }
        transfer.lastProgress = now
        transfers[downloadTask.taskIdentifier] = transfer
        lock.unlock()
        progress?(transfer.token, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let transfer = transfers[downloadTask.taskIdentifier]
        lock.unlock()
        guard let transfer else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw DownloadError.http(status)
            }
            guard let responseURL = downloadTask.response?.url, AppleDownloadPolicy.permits(responseURL) else {
                throw DownloadError.message("The firmware response did not come from an approved Apple HTTPS host.")
            }
            try FileManager.default.moveItem(at: location, to: transfer.staging)
            finished?(transfer.token, .success(transfer.staging))
        } catch { finished?(transfer.token, .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let transfer, let error { failed?(transfer.token, error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, AppleDownloadPolicy.permits(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
