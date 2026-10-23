import Foundation

/// A metadata-only plan. The caller must revalidate each managed local file
/// before removing it. Signing evidence is a snapshot reported by IPSW.me.
public struct FirmwareCleanupPlan: Sendable, Equatable {
    public let unsignedDownloadIDs: [String]
    /// The earliest linked-model metadata timestamp plus the signing evidence
    /// lifetime. Recheck this after hashing and immediately before file removal.
    public let signingApprovalExpirations: [String: Date]
    /// Ready entries with resolved evidence for every associated model,
    /// including entries retained because at least one model is still signed.
    public let checkedCount: Int
    /// Ready entries retained because their identity or signing state is uncertain.
    public let skippedCount: Int
    public let warnings: [String]

    public init(unsignedDownloadIDs: [String], checkedCount: Int,
                skippedCount: Int, warnings: [String] = [],
                signingApprovalExpirations: [String: Date] = [:]) {
        self.unsignedDownloadIDs = unsignedDownloadIDs
        self.signingApprovalExpirations = signingApprovalExpirations
        self.checkedCount = checkedCount; self.skippedCount = skippedCount
        self.warnings = warnings
    }
}

/// Evaluates completed downloads without inspecting or mutating files. One
/// history request is made per model, sequentially, during each evaluation.
public struct FirmwareCleanupService: Sendable {
    private let fetchHistory: @Sendable (String) async throws -> FirmwareHistory

    public init(fetchHistory: @escaping @Sendable (String) async throws -> FirmwareHistory = {
        try await FirmwareHistoryService().fetch(deviceIdentifier: $0)
    }) {
        self.fetchHistory = fetchHistory
    }

    public func evaluate(_ items: [DownloadItem]) async throws -> FirmwareCleanupPlan {
        try Task.checkCancellation()
        let ready = items.filter { $0.status == .ready }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        var candidates: [DownloadItem] = []
        var warnings: [String] = []
        var skipped = 0

        for item in ready {
            try Task.checkCancellation()
            let issue: String?
            if !item.allowsAutomaticCleanup {
                issue = "this imported file is protected from automatic cleanup"
            } else if item.id.isEmpty || counts[item.id] != 1 {
                issue = "the queue identifier is missing or duplicated"
            } else if item.modelIdentifiers.isEmpty || !item.modelIdentifiers.allSatisfy(Self.validIdentifier) {
                issue = "the associated device identifiers are missing or invalid"
            } else if item.version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}\z"#, options: .regularExpression) == nil
                        || item.build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !Self.validFirmwareURL(item.url) {
                issue = "the saved firmware identity or Apple download URL is invalid"
            } else {
                issue = nil
            }
            if let issue {
                skipped += 1
                warnings.append(Self.keptMessage(item, reason: issue))
            } else {
                candidates.append(item)
            }
        }

        let identifiers = Set(candidates.flatMap(\.modelIdentifiers)).sorted()
        var histories: [String: FirmwareHistory] = [:]
        for identifier in identifiers {
            try Task.checkCancellation()
            do {
                let history = try await fetchHistory(identifier)
                try Task.checkCancellation()
                guard history.deviceIdentifier == identifier else {
                    warnings.append("Could not check \(identifier): the history response identifies a different model.")
                    continue
                }
                histories[identifier] = history
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                warnings.append("Could not check \(identifier): \(error.localizedDescription)")
            }
        }

        var unsigned: [String] = []
        var signingApprovalExpirations: [String: Date] = [:]
        var checked = 0
        let evaluatedAt = Date()
        for item in candidates {
            try Task.checkCancellation()
            var hasSignedModel = false
            var uncertainties: [String] = []
            var earliestHistoryDate: Date?
            let expectedURL = DownloadManager.identifier(for: item.url)
            for identifier in Set(item.modelIdentifiers).sorted() {
                guard let history = histories[identifier] else {
                    uncertainties.append("\(identifier) could not be checked")
                    continue
                }
                // The default fetcher always requests live metadata. This also
                // rejects stale injected/cache results and checks that early
                // responses have not aged out during an unusually long check.
                let age = evaluatedAt.timeIntervalSince(history.fetchedAt)
                guard age >= -60, age <= 15 * 60 else {
                    uncertainties.append("\(identifier) has stale or future-dated signing metadata")
                    continue
                }
                earliestHistoryDate = min(earliestHistoryDate ?? history.fetchedAt, history.fetchedAt)
                let sameRelease = history.releases.filter { $0.version == item.version && $0.build == item.build }
                guard !sameRelease.isEmpty else {
                    uncertainties.append("\(identifier) has no matching version and build")
                    continue
                }
                guard !sameRelease.contains(where: \.isSigningStatusConflicting) else {
                    uncertainties.append("\(identifier) has conflicting signing metadata")
                    continue
                }
                let exact = sameRelease.filter { release in
                    guard let url = release.downloadURL, Self.validFirmwareURL(url) else { return false }
                    return DownloadManager.identifier(for: url) == expectedURL
                }
                guard !exact.isEmpty else {
                    uncertainties.append("\(identifier) has no matching Apple IPSW URL")
                    continue
                }
                // Any signed report for the exact version/build is sufficient
                // to keep the file, including another URL for that release.
                if sameRelease.contains(where: \.isSigned) { hasSignedModel = true }
            }
            if uncertainties.isEmpty {
                checked += 1
                if !hasSignedModel, let earliestHistoryDate {
                    unsigned.append(item.id)
                    signingApprovalExpirations[item.id] = earliestHistoryDate.addingTimeInterval(15 * 60)
                }
            } else {
                skipped += 1
                warnings.append(Self.keptMessage(item, reason: uncertainties.joined(separator: "; ")))
            }
        }
        try Task.checkCancellation()
        return FirmwareCleanupPlan(unsignedDownloadIDs: unsigned, checkedCount: checked,
                                   skippedCount: skipped, warnings: warnings,
                                   signingApprovalExpirations: signingApprovalExpirations)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^(iPhone|iPad)[0-9]+,[0-9]+\z"#, options: .regularExpression) != nil
    }

    private static func validFirmwareURL(_ url: URL) -> Bool {
        AppleDownloadPolicy.permits(url) && url.pathExtension.lowercased() == "ipsw"
    }

    private static func keptMessage(_ item: DownloadItem, reason: String) -> String {
        "Kept \(item.name) \(item.version) (\(item.build)): \(reason)."
    }
}
