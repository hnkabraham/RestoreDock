import AppKit
import Combine
import FirmwareCore
import ServiceManagement
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

enum Screen: String, CaseIterable, Identifiable {
    case library = "Overview", devices = "Devices", downloads = "Downloads", storage = "Storage", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .devices: return "ipad.and.iphone"
        case .downloads: return "arrow.down.circle"
        case .storage: return "externaldrive"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct Preferences: Codable {
    var selectedIDs: Set<String> = []
    var allSupported = false
    var automaticDownloads = false
    var automaticallyDeleteUnsigned = false
    var intervalHours = 6
    var reserveGB = 20
    var destinationPath = FirmwareDestination.preferredDirectory().path
    var notifications = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case selectedIDs, allSupported, automaticDownloads, automaticallyDeleteUnsigned, intervalHours, reserveGB, destinationPath, notifications
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedIDs) ?? selectedIDs
        allSupported = try values.decodeIfPresent(Bool.self, forKey: .allSupported) ?? allSupported
        automaticDownloads = try values.decodeIfPresent(Bool.self, forKey: .automaticDownloads) ?? automaticDownloads
        automaticallyDeleteUnsigned = try values.decodeIfPresent(Bool.self, forKey: .automaticallyDeleteUnsigned) ?? false
        intervalHours = try values.decodeIfPresent(Int.self, forKey: .intervalHours) ?? intervalHours
        reserveGB = try values.decodeIfPresent(Int.self, forKey: .reserveGB) ?? reserveGB
        destinationPath = FirmwareDestination.preferredDirectory(savedPath: try values.decodeIfPresent(String.self, forKey: .destinationPath)).path
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
    }
}

struct CleanupReport: Codable {
    let date: Date
    let checkedCount: Int
    let removedCount: Int
    let reclaimedBytes: Int64
    let skippedCount: Int
    let warnings: [String]
}

struct ImportResultRow: Identifiable {
    let id = UUID()
    let file: URL
    let message: String
    let succeeded: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen = .library
    @Published var preferences: Preferences { didSet { savePreferences() } }
    @Published private(set) var catalog: CatalogSnapshot?
    @Published private(set) var refreshing = false
    @Published var errorMessage: String?
    @Published var search = ""
    @Published var family = "All devices"
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var cleaningUp = false
    @Published private(set) var cleanupReport: CleanupReport?
    @Published private(set) var cleanupProgress = ""
    @Published var showImport = false
    @Published private(set) var importSelections: [URL] = []
    @Published private(set) var importing = false
    @Published private(set) var importProgress = ""
    @Published private(set) var importResults: [ImportResultRow] = []
    @Published private(set) var storageSnapshot: FirmwareStorageSnapshot?
    @Published private(set) var storageRefreshing = false
    @Published private(set) var storageError: String?
    @Published private(set) var cleanupPreview: FirmwareStorageCleanupPreview?
    @Published private(set) var previewingCleanup = false
    let downloads: DownloadManager
    let stateDirectory: URL
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var downloadObserver: AnyCancellable?
    private var knownReady: Set<String> = []
    private var lastAttempt: Date?
    private var lastCleanupAttempt: Date?
    private var cleanupTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var importTask: Task<Void, Never>?
    private var importGeneration = UUID()
    private var storageTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var lastLibraryInventory: [DownloadItem] = []

    init() {
        // Keep the original state location so existing libraries and preferences
        // remain available after the RestoreDock rename.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FirmwareShelf", isDirectory: true)
        stateDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let saved = (try? Data(contentsOf: base.appendingPathComponent("preferences.json"))).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        preferences = saved
        cleanupReport = (try? Data(contentsOf: base.appendingPathComponent("cleanup.json"))).flatMap { try? JSONDecoder().decode(CleanupReport.self, from: $0) }
        catalog = (try? Data(contentsOf: base.appendingPathComponent("catalog.json"))).flatMap { try? JSONDecoder().decode(CatalogSnapshot.self, from: $0) }
        downloads = DownloadManager(stateDirectory: base.appendingPathComponent("queue"), destinationDirectory: URL(fileURLWithPath: saved.destinationPath, isDirectory: true))
        downloads.destinationDirectory = URL(fileURLWithPath: saved.destinationPath, isDirectory: true)
        downloads.reserveBytes = Int64(saved.reserveGB) * 1_000_000_000
        knownReady = Set(downloads.items.filter { $0.status == .ready }.map(\.id))
        downloadObserver = downloads.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.announceCompletions()
                self?.libraryDidChange()
            }
        }
        lastLibraryInventory = libraryInventory
        refreshLoginStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
        Task { await refresh() }
    }

    var allDevices: [DeviceFirmware] { catalog?.devices ?? [] }
    var trackedDevices: [DeviceFirmware] { allDevices.filter { isTracked($0.id) } }
    var filteredDevices: [DeviceFirmware] {
        allDevices.filter { device in
            (family == "All devices" || (family == "iPhone" ? device.id.hasPrefix("iPhone") : device.id.hasPrefix("iPad"))) &&
            (search.isEmpty || "\(device.name) \(device.id) \(device.version)".localizedCaseInsensitiveContains(search))
        }
    }
    var readyItems: [DownloadItem] { downloads.items.filter { $0.status == .ready } }
    var pendingItems: [DownloadItem] { downloads.items.filter { $0.status != .ready } }
    var uniqueTrackedCount: Int { Set(trackedDevices.map(\.downloadURL)).count }
    var nextCheck: Date? { catalog.map { $0.fetchedAt.addingTimeInterval(Double(preferences.intervalHours) * 3600) } }
    var librarySize: Int64 { readyItems.reduce(0) { $0 + $1.downloadedBytes } }
    var configuratorDirectory: URL { FirmwareDestination.configuratorDirectory() }
    var configuratorDirectoryExists: Bool { FirmwareDestination.directoryExists(at: configuratorDirectory) }
    var isUsingConfiguratorDirectory: Bool {
        FirmwareDestination.sameDirectory(URL(fileURLWithPath: preferences.destinationPath, isDirectory: true), configuratorDirectory)
    }
    var availableBytes: Int64? {
        let url = URL(fileURLWithPath: preferences.destinationPath)
        let existing = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    func isTracked(_ id: String) -> Bool { preferences.allSupported || preferences.selectedIDs.contains(id) }
    func setTracked(_ id: String, value: Bool) {
        if preferences.allSupported {
            preferences.selectedIDs = Set(allDevices.map(\.id))
            preferences.allSupported = false
        }
        if value { preferences.selectedIDs.insert(id) } else { preferences.selectedIDs.remove(id) }
        if value && preferences.automaticDownloads { enqueueTracked(automatically: true) }
    }
    func selectAll(_ enabled: Bool) {
        preferences.allSupported = enabled
        if !enabled { preferences.selectedIDs = [] }
        if enabled && preferences.automaticDownloads { enqueueTracked(automatically: true) }
    }
    func setAutomatic(_ enabled: Bool) {
        preferences.automaticDownloads = enabled
        if enabled { enqueueTracked(automatically: true); downloads.resume() }
    }
    func enqueueTracked(automatically: Bool = false) { downloads.enqueue(trackedDevices, automatically: automatically) }
    func refreshIfDue() async {
        guard !isShuttingDown else { return }
        let catalogBackoffElapsed = lastAttempt.map { Date().timeIntervalSince($0) >= 15 * 60 } ?? true
        if !refreshing && catalogBackoffElapsed && (catalog == nil || Date() >= (nextCheck ?? .distantPast)) { await refresh() }
        startCleanupIfDue()
    }
    func refresh() async {
        guard !refreshing, !isShuttingDown else { return }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }
        do {
            let snapshot = try await CatalogService().fetch()
            guard !isShuttingDown else { return }
            catalog = snapshot
            try JSONEncoder().encode(snapshot).write(to: stateDirectory.appendingPathComponent("catalog.json"), options: .atomic)
            errorMessage = nil
            if preferences.automaticDownloads { enqueueTracked(automatically: true) }
        } catch {
            errorMessage = "Couldn't refresh the firmware catalog. \(error.localizedDescription) Your saved library is still available."
        }
        startCleanupIfDue()
    }

    func setAutomaticCleanup(_ enabled: Bool) {
        preferences.automaticallyDeleteUnsigned = enabled
        if enabled { startCleanup(force: true) }
        else {
            cleanupTask?.cancel()
            lastCleanupAttempt = nil
            cleanupProgress = cleaningUp ? "Stopping cleanup…" : ""
        }
    }
    private func startCleanupIfDue() { startCleanup(force: false) }
    func startCleanup(force: Bool = true) {
        guard preferences.automaticallyDeleteUnsigned, !cleaningUp, !importing, !previewingCleanup, !isShuttingDown else { return }
        if !force, let lastCleanupAttempt,
           Date().timeIntervalSince(lastCleanupAttempt) < Double(preferences.intervalHours) * 3600 { return }
        lastCleanupAttempt = Date()
        cleaningUp = true
        cleanupProgress = "Checking signing status…"
        let snapshot = readyItems
        cleanupTask = Task { await cleanUnsignedDownloads(snapshot) }
    }

    private func cleanUnsignedDownloads(_ snapshot: [DownloadItem]) async {
        var removedCount = 0
        var reclaimedBytes: Int64 = 0
        var checkedCount = 0
        var skippedCount = 0
        var warnings: [String] = []
        defer {
            cleanupReport = CleanupReport(date: Date(), checkedCount: checkedCount, removedCount: removedCount,
                reclaimedBytes: reclaimedBytes, skippedCount: skippedCount, warnings: warnings)
            if let cleanupReport {
                do { try JSONEncoder().encode(cleanupReport).write(to: stateDirectory.appendingPathComponent("cleanup.json"), options: .atomic) }
                catch { errorMessage = "Couldn't save the cleanup report: \(error.localizedDescription)" }
            }
            cleaningUp = false
            cleanupProgress = ""
            cleanupTask = nil
        }
        do {
            let plan = try await FirmwareCleanupService().evaluate(snapshot)
            try Task.checkCancellation()
            checkedCount = plan.checkedCount
            skippedCount = plan.skippedCount
            warnings = plan.warnings
            for id in plan.unsignedDownloadIDs {
                try Task.checkCancellation()
                guard preferences.automaticallyDeleteUnsigned else { throw CancellationError() }
                guard let original = snapshot.first(where: { $0.id == id }),
                      downloads.items.first(where: { $0.id == id }) == original else {
                    skippedCount += 1
                    warnings.append("A download changed during the signing check and was kept.")
                    continue
                }
                var approvalExpiresAt = plan.signingApprovalExpirations[id] ?? .distantPast
                if approvalExpiresAt.timeIntervalSinceNow < 5 * 60 {
                    // Large batches can outlive the first metadata check. Get
                    // new evidence for this file before its checksum is read.
                    let recheck = try await FirmwareCleanupService().evaluate([original])
                    try Task.checkCancellation()
                    guard recheck.unsignedDownloadIDs.contains(id),
                          let renewedExpiry = recheck.signingApprovalExpirations[id] else {
                        skippedCount += 1
                        warnings.append("\(original.name) \(original.version): unsigned status could not be reconfirmed; kept.")
                        warnings.append(contentsOf: recheck.warnings)
                        continue
                    }
                    approvalExpiresAt = renewedExpiry
                }
                guard preferences.automaticallyDeleteUnsigned,
                      downloads.items.first(where: { $0.id == id }) == original else { throw CancellationError() }
                cleanupProgress = "Verifying \(original.name) \(original.version) before deletion…"
                switch await downloads.removeUnsignedDownload(id, signingApprovalExpiresAt: approvalExpiresAt) {
                case .removed:
                    removedCount += 1
                    reclaimedBytes += original.downloadedBytes
                case .missing:
                    skippedCount += 1
                    warnings.append("\(original.name) \(original.version): file or drive is unavailable; entry kept.")
                case .notEligible:
                    skippedCount += 1
                    warnings.append(approvalExpiresAt <= Date()
                        ? "\(original.name) \(original.version): the signing check expired during verification; kept."
                        : "\(original.name) \(original.version): the file changed or couldn't be verified as a managed download; kept.")
                case .failed(let message):
                    skippedCount += 1
                    warnings.append("\(original.name) \(original.version): \(message)")
                }
            }
        } catch is CancellationError {
            warnings.append("Cleanup stopped. Files not already removed were kept.")
        } catch {
            warnings.append("Cleanup couldn't complete: \(error.localizedDescription) Files with unknown signing status were kept.")
        }
    }

    func shutdown() {
        isShuttingDown = true
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        cleanupTask?.cancel()
        importTask?.cancel()
        storageTask?.cancel()
        previewTask?.cancel()
        downloads.shutdown()
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your firmware library"
        panel.message = "Use a local folder or a mounted external drive with enough space for your selected models."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: preferences.destinationPath)
        if panel.runModal() == .OK, let url = panel.url {
            updateDestination(url, createIfNeeded: false)
        }
    }
    func useConfiguratorDirectory(createIfNeeded: Bool) {
        updateDestination(configuratorDirectory, createIfNeeded: createIfNeeded)
    }
    private func updateDestination(_ url: URL, createIfNeeded: Bool) {
        do {
            let directory = try FirmwareDestination.prepareDirectory(at: url, createIfNeeded: createIfNeeded)
            errorMessage = nil
            preferences.destinationPath = directory.path
            downloads.destinationDirectory = directory
        } catch { errorMessage = "Couldn't use the firmware folder: \(error.localizedDescription)" }
    }
    func revealLibrary() {
        let url = URL(fileURLWithPath: preferences.destinationPath, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
        catch { errorMessage = "Couldn't open the library folder: \(error.localizedDescription)" }
    }
    func reveal(_ item: DownloadItem) {
        guard item.completedAt != nil, let path = item.localPath,
              FileManager.default.fileExists(atPath: path) else {
            errorMessage = "This file is unavailable. Reconnect its drive or import it from its current location."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func setReserve(_ gb: Int) {
        preferences.reserveGB = gb
        downloads.reserveBytes = Int64(gb) * 1_000_000_000
    }
    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch { errorMessage = "Couldn't update Open at Login: \(error.localizedDescription)"; refreshLoginStatus() }
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { preferences.notifications = false; return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                preferences.notifications = granted
                if !granted { errorMessage = "Notifications are disabled in macOS. Enable them for RestoreDock in System Settings → Notifications." }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func announceCompletions() {
        let ready = downloads.items.filter { $0.status == .ready }
        for item in ready where !knownReady.contains(item.id) && preferences.notifications {
            let content = UNMutableNotificationContent()
            content.title = "Firmware ready to restore"
            content.body = item.importedAt == nil ? "\(item.name) · \(item.version) has finished downloading and verifying." : "\(item.name) · \(item.version) was verified and added to your library."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
        knownReady = Set(ready.map(\.id))
    }
    private func savePreferences() {
        do { try JSONEncoder().encode(preferences).write(to: stateDirectory.appendingPathComponent("preferences.json"), options: .atomic) }
        catch { errorMessage = "Couldn't save settings: \(error.localizedDescription)" }
    }
}

extension AppModel {
    private var libraryInventory: [DownloadItem] {
        downloads.items.filter { $0.status == .ready || $0.completedAt != nil }
    }

    private func libraryDidChange() {
        let current = libraryInventory
        guard current != lastLibraryInventory else { return }
        lastLibraryInventory = current
        cleanupPreview = nil
        if screen == .storage { refreshStorage() }
    }

    var cleanupPreviewIsStale: Bool {
        guard let preview = cleanupPreview else { return false }
        return Date() >= (preview.expiresAt ?? preview.checkedAt.addingTimeInterval(15 * 60))
    }

    func refreshStorage() {
        guard !storageRefreshing, !isShuttingDown else { return }
        storageRefreshing = true
        let snapshot = libraryInventory
        storageTask = Task {
            do {
                let measured = try await FirmwareStorageService().snapshot(snapshot)
                try Task.checkCancellation()
                if libraryInventory == snapshot {
                    if storageSnapshot?.entries != measured.entries { cleanupPreview = nil }
                    storageSnapshot = measured
                    storageError = nil
                }
            } catch is CancellationError { }
            catch { storageError = "Couldn't measure the firmware library: \(error.localizedDescription)" }
            storageRefreshing = false
            storageTask = nil
            if !isShuttingDown, libraryInventory != snapshot { refreshStorage() }
        }
    }

    func previewCleanup() {
        guard !previewingCleanup, !cleaningUp, !importing, !isShuttingDown else { return }
        previewingCleanup = true
        cleanupPreview = nil
        storageError = nil
        let snapshot = libraryInventory
        previewTask = Task {
            defer { previewingCleanup = false; previewTask = nil }
            do {
                let plan = try await FirmwareCleanupService().evaluate(snapshot)
                let measured = try await FirmwareStorageService().snapshot(snapshot)
                try Task.checkCancellation()
                guard libraryInventory == snapshot else {
                    storageError = "Your library changed during the check. Refresh the cleanup preview."
                    return
                }
                storageSnapshot = measured
                cleanupPreview = measured.cleanupPreview(for: plan)
            } catch is CancellationError { }
            catch { storageError = "Couldn't preview cleanup: \(error.localizedDescription) No files were removed." }
        }
    }

    func chooseImportFiles() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Import existing IPSWs"
        panel.message = "Select IPSW files or folders to search, including subfolders. Files stay in their current locations."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: preferences.destinationPath)
        if panel.runModal() == .OK {
            importSelections = panel.urls
            importResults = []
            importProgress = ""
        }
    }

    func selectConfiguratorImport() {
        guard !importing, configuratorDirectoryExists else { return }
        importSelections = [configuratorDirectory]
        importResults = []
        importProgress = ""
    }

    func cancelImport() {
        importTask?.cancel()
        if importing { importProgress = "Stopping after the current operation…" }
    }

    func startImport(allowAutomaticCleanup: Bool) {
        guard !importing, !cleaningUp, !previewingCleanup, !importSelections.isEmpty, !isShuttingDown else { return }
        let selections = importSelections
        let generation = UUID()
        importGeneration = generation
        importing = true
        importResults = []
        importProgress = "Finding IPSW files…"
        importTask = Task {
            defer {
                importing = false
                importTask = nil
                refreshStorage()
            }
            do {
                let files = try await FirmwareImportService.discover(in: selections)
                if files.isEmpty {
                    importProgress = "No IPSW files were found in your selection."
                    return
                }
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    let prefix = "\(index + 1) of \(files.count) · \(file.lastPathComponent)"
                    importProgress = prefix
                    do {
                        let verified = try await FirmwareImportService().verify(file: file) { message in
                            Task { @MainActor in
                                guard self.importGeneration == generation, self.importing, self.importTask?.isCancelled != true else { return }
                                self.importProgress = "\(prefix)\n\(message)"
                            }
                        }
                        try Task.checkCancellation()
                        let result = try downloads.registerImport(verified, allowAutomaticCleanup: allowAutomaticCleanup)
                        let row: ImportResultRow
                        switch result {
                        case .imported:
                            row = ImportResultRow(file: file, message: (["Verified and imported · \(verified.version) (\(verified.build))"] + verified.warnings).joined(separator: "\n"), succeeded: true)
                        case .alreadyAvailable:
                            row = ImportResultRow(file: file, message: "Already in your library. No duplicate was added.", succeeded: true)
                        case .busy:
                            row = ImportResultRow(file: file, message: "This firmware is being downloaded or verified. Pause or finish that transfer, then import again.", succeeded: false)
                        }
                        importResults.append(row)
                    } catch {
                        try Task.checkCancellation()
                        importResults.append(ImportResultRow(file: file, message: error.localizedDescription, succeeded: false))
                    }
                }
                let failures = importResults.filter { !$0.succeeded }.count
                importProgress = "Import finished · \(importResults.count - failures) verified or already available · \(failures) skipped"
            } catch is CancellationError {
                importProgress = "Import stopped. Files already registered remain in your library."
            } catch {
                importProgress = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }
}

func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
