import Foundation
import Darwin

public enum FirmwareStorageAvailability: String, Sendable, Equatable {
    /// A regular file whose size still matches the previously verified download.
    /// This is a lightweight measurement, not a fresh checksum verification.
    case available, missing, unavailable, changed
}

public struct FirmwareStorageEntry: Identifiable, Sendable, Equatable {
    public var id: String { item.id }
    public let item: DownloadItem
    public let actualByteCount: Int64?
    public let availability: FirmwareStorageAvailability
    /// Filesystem device and inode identify hard links as one physical file.
    public let physicalFileID: String?
    public let detail: String?
    public let isSymbolicLink: Bool
}

public struct FirmwareStorageGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let byteCount: Int64
    public let fileCount: Int
    /// Files supporting multiple models, including models saved on other aliases.
    public let sharedFileCount: Int
}

public struct FirmwareStorageCleanupPreview: Sendable, Equatable {
    public let candidates: [FirmwareStorageEntry]
    /// Unique logical file sizes. APFS cloning, compression and untracked hard
    /// links mean this is not a promise of physical space recovered.
    public let totalByteCount: Int64
    public let expiresAt: Date?
    public let checkedCount: Int
    public let skippedCount: Int
    public let warnings: [String]
    public let checkedAt: Date
}

public struct FirmwareStorageSnapshot: Sendable, Equatable {
    public let entries: [FirmwareStorageEntry]
    /// Actual logical size of unique, present regular files, including files
    /// that have changed size. Missing files never contribute cached byte counts.
    public let totalByteCount: Int64
    public let readyFileCount: Int
    public let presentFileCount: Int
    public let missingCount: Int
    public let unavailableCount: Int
    public let changedCount: Int
    public let importedCount: Int
    /// Model groups overlap when one IPSW serves several models.
    public let modelGroups: [FirmwareStorageGroup]
    /// Version groups partition physical files; conflicting saved identities
    /// appear in a separate group instead of being counted twice.
    public let versionGroups: [FirmwareStorageGroup]
    public let measuredAt: Date

    /// Combines a signing snapshot with this read-only file measurement. This
    /// never authorizes deletion by itself; removal must recheck the current
    /// file, checksum, queue entry and signing evidence expiry.
    public func cleanupPreview(for plan: FirmwareCleanupPlan) -> FirmwareStorageCleanupPreview {
        let checkedAt = Date()
        let eligible = Set(plan.unsignedDownloadIDs)
        let aliases = Dictionary(grouping: entries.compactMap { entry -> FirmwareStorageEntry? in
            entry.physicalFileID == nil ? nil : entry
        }, by: { $0.physicalFileID! })
        var candidates: [FirmwareStorageEntry] = []
        var warnings = plan.warnings
        var skipped = plan.skippedCount
        var expiry: Date?
        var countedFiles: Set<String> = []
        var total: Int64 = 0
        for entry in entries where eligible.contains(entry.id) {
            let reason: String?
            if !entry.item.allowsAutomaticCleanup {
                reason = "this imported file is protected from automatic cleanup"
            } else if entry.item.status != .ready || entry.availability != .available {
                reason = entry.detail ?? "the completed file is missing, unavailable or changed"
            } else if entry.isSymbolicLink {
                reason = "the saved path is a symbolic link"
            } else if DownloadManager.managedCompletedURL(for: entry.item) == nil {
                reason = "the saved completion, checksum or file location cannot be verified as a managed IPSW"
            } else if let fileID = entry.physicalFileID,
                      Set(aliases[fileID, default: []].map(\.id)).count > 1 {
                reason = "multiple tracked entries reference this same physical file"
            } else if let fileID = entry.physicalFileID,
                      aliases[fileID, default: []].contains(where: {
                          !eligible.contains($0.id) || !$0.item.allowsAutomaticCleanup ||
                          $0.availability != .available || $0.item.status != .ready || $0.isSymbolicLink ||
                          (plan.signingApprovalExpirations[$0.id] ?? .distantPast) <= checkedAt
                      }) {
                reason = "another tracked reference to this file is not eligible for cleanup"
            } else if (plan.signingApprovalExpirations[entry.id] ?? .distantPast) <= checkedAt {
                reason = "the signing check has expired or has no expiry"
            } else if entry.physicalFileID == nil || entry.actualByteCount == nil {
                reason = "the local file could not be measured"
            } else {
                reason = nil
            }
            if let reason {
                skipped += 1
                warnings.append("Kept \(entry.item.name) \(entry.item.version): \(reason).")
                continue
            }
            candidates.append(entry)
            if let value = plan.signingApprovalExpirations[entry.id] {
                expiry = min(expiry ?? value, value)
            }
            if let fileID = entry.physicalFileID, countedFiles.insert(fileID).inserted {
                total += entry.actualByteCount ?? 0
            }
        }
        return FirmwareStorageCleanupPreview(candidates: candidates, totalByteCount: total,
            expiresAt: expiry, checkedCount: plan.checkedCount, skippedCount: skipped,
            warnings: warnings, checkedAt: checkedAt)
    }
}

/// Measures only tracked completed files. It does not scan directories, hash
/// large IPSWs, change queue state or mutate any file.
public struct FirmwareStorageService: Sendable {
    public init() {}

    public func snapshot(_ items: [DownloadItem]) async throws -> FirmwareStorageSnapshot {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try Self.measure(items) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { task.cancel() })
    }

    private static func measure(_ items: [DownloadItem]) throws -> FirmwareStorageSnapshot {
        var entries: [FirmwareStorageEntry] = []
        for item in items where item.status == .ready || (item.status == .failed && item.completedAt != nil) {
            try Task.checkCancellation()
            entries.append(inspect(item))
        }
        let files = Dictionary(grouping: entries.filter { $0.physicalFileID != nil && $0.actualByteCount != nil },
                               by: { $0.physicalFileID! })
        var models: [String: [String]] = [:]
        var versions: [String: [String]] = [:]
        var versionLabels: [String: String] = [:]
        var sizes: [String: Int64] = [:]
        var shared: Set<String> = []
        var ready = 0
        var imported = 0
        for (fileID, references) in files {
            try Task.checkCancellation()
            // A file could change between two alias measurements. Use its
            // largest observation for display, and never mark that file ready.
            let observations = Set(references.compactMap(\.actualByteCount))
            sizes[fileID] = observations.max() ?? 0
            if observations.count == 1 && references.allSatisfy({ $0.availability == .available }) { ready += 1 }
            if references.contains(where: { $0.item.importedAt != nil }) { imported += 1 }
            let identifiers = Set(references.flatMap { $0.item.modelIdentifiers })
            if identifiers.count > 1 { shared.insert(fileID) }
            for identifier in identifiers.isEmpty ? ["Unknown model"] : identifiers.sorted() {
                models[identifier, default: []].append(fileID)
            }
            let releaseKeys = Set(references.map { $0.item.version + "|" + $0.item.build })
            let key = releaseKeys.count == 1 ? releaseKeys.first! : "conflicting-saved-versions"
            versions[key, default: []].append(fileID)
            if releaseKeys.count == 1, let item = references.first?.item {
                versionLabels[key] = "\(item.version) (\(item.build))"
            } else { versionLabels[key] = "Conflicting saved versions" }
        }
        func groups(_ values: [String: [String]], labels: [String: String] = [:]) -> [FirmwareStorageGroup] {
            values.map { key, ids in
                FirmwareStorageGroup(id: key, label: labels[key] ?? key,
                    byteCount: ids.reduce(0) { $0 + (sizes[$1] ?? 0) }, fileCount: ids.count,
                    sharedFileCount: ids.filter { shared.contains($0) }.count)
            }.sorted {
                if $0.byteCount != $1.byteCount { return $0.byteCount > $1.byteCount }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
        }
        try Task.checkCancellation()
        return FirmwareStorageSnapshot(entries: entries, totalByteCount: sizes.values.reduce(0, +),
            readyFileCount: ready, presentFileCount: files.count,
            missingCount: entries.filter { $0.availability == .missing }.count,
            unavailableCount: entries.filter { $0.availability == .unavailable }.count,
            changedCount: entries.filter { $0.availability == .changed }.count, importedCount: imported,
            modelGroups: groups(models), versionGroups: groups(versions, labels: versionLabels), measuredAt: Date())
    }

    private static func inspect(_ item: DownloadItem) -> FirmwareStorageEntry {
        func result(_ availability: FirmwareStorageAvailability, _ detail: String,
                    bytes: Int64? = nil, fileID: String? = nil, symlink: Bool = false) -> FirmwareStorageEntry {
            FirmwareStorageEntry(item: item, actualByteCount: bytes, availability: availability,
                                 physicalFileID: fileID, detail: detail, isSymbolicLink: symlink)
        }
        guard let path = item.localPath, path.hasPrefix("/"), !path.contains("\0") else {
            return result(.unavailable, "No valid absolute path was saved for this file.")
        }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        var linkInfo = stat()
        guard lstat(original.path, &linkInfo) == 0 else {
            let code = errno
            return result(code == ENOENT || code == ENOTDIR ? .missing : .unavailable,
                          code == ENOENT || code == ENOTDIR ? "The file is missing or its drive is disconnected." : "The file cannot be inspected (filesystem error \(code)).")
        }
        let symlink = linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else {
            let code = errno
            return result(code == ENOENT || code == ENOTDIR ? .missing : .unavailable,
                          "The file's resolved location is missing or unavailable.", symlink: symlink)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            return result(.unavailable, "The saved path does not identify a regular file.", symlink: symlink)
        }
        let bytes = Int64(info.st_size)
        let fileID = info.st_ino == 0 ? "path:\(resolved.path)" : "inode:\(info.st_dev):\(info.st_ino)"
        guard bytes > 0, item.downloadedBytes > 0, bytes == item.downloadedBytes else {
            return result(.changed, "The file's size differs from its saved verified size.", bytes: bytes, fileID: fileID, symlink: symlink)
        }
        return FirmwareStorageEntry(item: item, actualByteCount: bytes, availability: .available,
                                    physicalFileID: fileID, detail: nil, isSymbolicLink: symlink)
    }
}
