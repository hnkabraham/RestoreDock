import FirmwareCore
import SwiftUI

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    @State private var breakdown: Breakdown = .version
    @State private var showAllGroups = false

    private enum Breakdown: String, CaseIterable, Identifiable {
        case version = "By version", model = "By model"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                heading
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Color.orange)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                if let snapshot = model.storageSnapshot {
                    metrics(snapshot)
                    if snapshot.entries.isEmpty {
                        emptyLibrary
                    } else {
                        availabilityNotice(snapshot)
                        sizeBreakdown(snapshot)
                        cleanupPreviewCard
                        files(snapshot)
                    }
                    Text("Measured \(snapshot.measuredAt.formatted(date: .abbreviated, time: .shortened)). Sizes reflect files currently on disk. Shared files count once in the total; downloads in progress are excluded.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
                } else if model.storageRefreshing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Measuring your firmware library…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70).card()
                } else {
                    emptyLibrary
                }
            }.padding(30)
        }.onAppear { model.refreshStorage() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Room for the next restore.").font(.system(size: 26, weight: .semibold)).tracking(-0.7)
                Text("See what’s taking up space and bring existing IPSWs into your library.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 11) {
                Button { model.showImport = true } label: {
                    Label("Import existing IPSWs", systemImage: "square.and.arrow.down")
                }.buttonStyle(PrimaryButtonStyle())
                Button { model.scanFirmwareFolder() } label: {
                    Label("Find models to follow", systemImage: "doc.text.magnifyingglass")
                }.buttonStyle(SecondaryButtonStyle())
                Button { model.refreshStorage() } label: {
                    Label("Refresh sizes", systemImage: "arrow.clockwise")
                }.buttonStyle(SecondaryButtonStyle()).disabled(model.storageRefreshing)
                if model.storageRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metrics(_ snapshot: FirmwareStorageSnapshot) -> some View {
        HStack(spacing: 14) {
            MetricCard(value: byteString(snapshot.totalByteCount), title: "Library size", detail: "Shared files counted once", icon: "externaldrive")
            MetricCard(value: "\(snapshot.presentFileCount)", title: "IPSW files on disk", detail: "\(snapshot.readyFileCount) with unchanged file sizes", icon: "doc.zipper")
            MetricCard(value: "\(snapshot.importedCount)", title: "Imported files", detail: "Existing firmware added to your library", icon: "square.and.arrow.down")
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 33, weight: .light)).foregroundStyle(Palette.blue)
            Text("Already have the firmware?").font(.system(size: 17, weight: .semibold))
            Text("Import files from your Configurator cache or another folder.\nRestoreDock verifies each IPSW before adding it to your library.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
            Button("Import existing IPSWs") { model.showImport = true }
                .buttonStyle(PrimaryButtonStyle()).padding(.top, 3)
            Text("Your storage breakdown and cleanup preview will appear here.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 3)
        }.frame(maxWidth: .infinity).padding(.vertical, 42).padding(.horizontal, 20).card()
    }

    @ViewBuilder private func availabilityNotice(_ snapshot: FirmwareStorageSnapshot) -> some View {
        if snapshot.missingCount + snapshot.unavailableCount + snapshot.changedCount > 0 {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Some files need a closer look").font(.system(size: 12, weight: .semibold))
                    Text(availabilitySummary(snapshot)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text("Reconnect any external drives and refresh. Missing and unavailable files are excluded from the size total; changed files show their current size and are kept out of the cleanup preview.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                }
                Spacer(minLength: 0)
            }.padding(18).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.orange.opacity(0.18)))
        }
    }

    private func sizeBreakdown(_ snapshot: FirmwareStorageSnapshot) -> some View {
        let groups = breakdown == .version ? snapshot.versionGroups : snapshot.modelGroups
        let visibleGroups = showAllGroups ? groups : Array(groups.prefix(6))
        let largest = max(groups.map(\.byteCount).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Where the space goes").font(.system(size: 16, weight: .semibold))
                    Text(breakdown == .version ? "File sizes grouped by iOS or iPadOS release." : "Files available for each device model.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Picker("Storage breakdown", selection: $breakdown) {
                    ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                    .onChange(of: breakdown) { _, _ in showAllGroups = false }
            }
            if groups.isEmpty {
                Text("No accessible file sizes to display.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 12)
            } else {
                VStack(spacing: 16) {
                    ForEach(visibleGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(groupTitle(group)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Spacer(minLength: 4)
                                Text("\(group.fileCount) \(group.fileCount == 1 ? "file" : "files")")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                Text(byteString(group.byteCount)).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(minWidth: 67, alignment: .trailing)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(Palette.ice.opacity(0.55))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(LinearGradient(colors: [Palette.blue, Palette.sky], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(group.byteCount > 0 ? 4 : 0, geometry.size.width * CGFloat(group.byteCount) / CGFloat(largest)))
                                    }
                            }.frame(height: 7).accessibilityHidden(true)
                        }
                    }
                }
            }
            if groups.count > 6 {
                Button(showAllGroups ? "Show fewer" : "Show all \(groups.count) \(breakdown == .version ? "releases" : "models")") { showAllGroups.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
            }
            if breakdown == .model {
                Label("A shared IPSW appears under every linked model. Model totals overlap; the overall library total counts that file once.", systemImage: "square.stack.3d.up")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }.padding(22).card()
    }

    private var cleanupPreviewCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Palette.blue)
                    .frame(width: 42, height: 42).background(Palette.ice, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview your next cleanup").font(.system(size: 16, weight: .semibold))
                    Text("Check fresh signing data to see which files could be removed.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if model.previewingCleanup { ProgressView().controlSize(.small).padding(.top, 8) }
            }
            HStack(spacing: 15) {
                Button(model.previewingCleanup ? "Checking signing status…" : model.cleanupPreview == nil ? "Check cleanup preview" : "Refresh preview") {
                    model.previewCleanup()
                }.buttonStyle(SecondaryButtonStyle()).disabled(model.previewingCleanup || model.cleaningUp || model.importing || model.storageRefreshing)
                Text("Previewing never deletes files.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            if let preview = model.cleanupPreview {
                Divider().overlay(Palette.line)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let expired = model.cleanupPreviewIsStale || (preview.expiresAt.map { $0 <= context.date } ?? false)
                    previewResults(preview, expired: expired)
                }
            } else {
                Text("Available even with automatic cleanup off. Files are eligible only when every linked model is reported unsigned by IPSW.me. Unknown signing status leaves files untouched.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            HStack {
                Label(model.preferences.automaticallyDeleteUnsigned ? "Automatic cleanup is on" : "Automatic cleanup is off", systemImage: model.preferences.automaticallyDeleteUnsigned ? "checkmark.circle" : "pause.circle")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button("Cleanup settings →") { model.screen = .settings }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
            }.padding(.top, 2)
        }.padding(22).background(Palette.ice.opacity(0.22), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
    }

    private func previewResults(_ preview: FirmwareStorageCleanupPreview, expired: Bool) -> some View {
        let files = Dictionary(grouping: preview.candidates, by: { $0.physicalFileID ?? $0.id })
            .values.compactMap { $0.first }.sorted { $0.item.filename.localizedStandardCompare($1.item.filename) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(byteString(preview.totalByteCount)).font(.system(size: 28, weight: .semibold)).tracking(-0.7).monospacedDigit()
                Text("in \(files.count) \(files.count == 1 ? "eligible file" : "eligible files")")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            Text("Checked \(preview.checkedAt.formatted(date: .abbreviated, time: .shortened)) · \(preview.checkedCount) checked · \(preview.skippedCount) skipped")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            if expired {
                Label("This preview has expired. Refresh it before relying on these estimates.", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            if files.isEmpty {
                Text(preview.skippedCount > 0 || !preview.warnings.isEmpty ? "No files are currently eligible. Review the notes for files that could not be checked." : "No unsigned files are eligible for cleanup.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.horizontal, 15) }
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipper").foregroundStyle(Palette.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.item.filename).font(.system(size: 11, weight: .medium)).lineLimit(2).textSelection(.enabled)
                                Text("Version \(entry.item.version) · \(entry.item.build)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 4)
                            Text(entry.actualByteCount.map(byteString) ?? "—").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }.padding(15)
                    }
                }.card()
            }
            Text("Estimated removable file bytes. Shared files count once. Actual disk space recovered can vary with APFS clones, compression, or other links to the same file. Cleanup rechecks eligibility and verifies each file before permanent deletion.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            if !preview.warnings.isEmpty {
                DisclosureGroup("Preview notes (\(preview.warnings.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func files(_ snapshot: FirmwareStorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Library entries").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(snapshot.entries.count) \(snapshot.entries.count == 1 ? "entry" : "entries")")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text("One file can serve several models. Entries that point to the same physical file count once in the library total.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            LazyVStack(spacing: 0) {
                ForEach(Array(snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.horizontal, 19) }
                    fileRow(entry)
                }
            }.card()
        }
    }

    private func fileRow(_ entry: FirmwareStorageEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.availability == .available ? "doc.zipper" : "exclamationmark.doc")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(availabilityColor(entry)).frame(width: 26).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.item.name).font(.system(size: 13, weight: .semibold))
                    Text("Version \(entry.item.version) · Build \(entry.item.build)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(entry.item.modelIdentifiers.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(entry.actualByteCount.map(byteString) ?? "—").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    Text(availabilityLabel(entry)).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(availabilityColor(entry)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(availabilityColor(entry).opacity(0.08), in: Capsule())
                }
            }
            Text(entry.item.filename).font(.system(size: 10, weight: .medium, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            if let path = entry.item.localPath {
                let displayPath = (path as NSString).abbreviatingWithTildeInPath
                Text(displayPath).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(2).help(displayPath)
            }
            if let detail = entry.detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.orange).textSelection(.enabled).lineSpacing(3)
            }
            HStack(spacing: 10) {
                if entry.item.importedAt != nil {
                    Label(entry.item.allowsAutomaticCleanup ? "Imported · cleanup allowed" : "Imported · protected from automatic cleanup", systemImage: entry.item.allowsAutomaticCleanup ? "square.and.arrow.down" : "lock.shield")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button("Show in Finder") { model.reveal(entry.item) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.blue)
                    .disabled(entry.availability == .missing || entry.availability == .unavailable)
            }
        }.padding(19)
    }

    private func groupTitle(_ group: FirmwareStorageGroup) -> String {
        guard breakdown == .model,
              let device = model.allDevices.first(where: { $0.id == group.id || $0.id == group.label }) else { return group.label }
        return "\(device.name) · \(device.id)"
    }

    private func availabilitySummary(_ snapshot: FirmwareStorageSnapshot) -> String {
        [(snapshot.missingCount, "missing"), (snapshot.changedCount, "changed"), (snapshot.unavailableCount, "unavailable")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    private func availabilityLabel(_ entry: FirmwareStorageEntry) -> String {
        switch entry.availability {
        case .available: return "Available"
        case .missing: return "Missing"
        case .unavailable: return "Unavailable"
        case .changed: return "Changed"
        }
    }

    private func availabilityColor(_ entry: FirmwareStorageEntry) -> Color {
        entry.availability == .available ? Palette.blue : .orange
    }
}
