import SwiftUI
import FirmwareCore

struct FirmwareFollowSuggestionsView: View {
    @EnvironmentObject var model: AppModel

    private var availableIDs: Set<String> {
        Set(model.firmwareSuggestionDevices.map(\.id))
    }

    private var selectedCount: Int {
        model.selectedFirmwareSuggestionIDs.intersection(availableIDs).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    folderCard
                    if model.scanningFirmwareModels {
                        progressCard
                    } else if let error = model.firmwareScanError {
                        errorCard(error)
                    } else if let report = model.firmwareScanReport {
                        if model.firmwareSuggestionDevices.isEmpty {
                            emptyState(scannedFileCount: report.scannedFileCount, hasIssues: !report.issues.isEmpty)
                        } else {
                            suggestions
                        }
                        if !model.unavailableFirmwareModelIDs.isEmpty {
                            unavailableModels
                        }
                        if !report.issues.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 13) {
                                    ForEach(report.issues.indices, id: \.self) { index in
                                        let issue = report.issues[index]
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(issue.fileURL.lastPathComponent)
                                                .font(.system(size: 11, weight: .medium))
                                            Text(issue.message)
                                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                        }.textSelection(.enabled)
                                    }
                                }.padding(.top, 12)
                            } label: {
                                Label("\(report.issues.count) \(report.issues.count == 1 ? "file needs" : "files need") attention", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }.padding(18).card()
                        }
                    } else if !model.firmwareScanProgress.isEmpty {
                        Label(model.firmwareScanProgress, systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .lineSpacing(4).padding(18).card()
                    }
                }.padding(28)
            }
            Divider().overlay(Palette.line)
            footer
        }
        .frame(width: 780, height: 720)
        .background(Palette.canvas).foregroundStyle(Palette.ink).tint(Palette.blue)
        .interactiveDismissDisabled(model.scanningFirmwareModels)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 17) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 25)).foregroundStyle(Palette.blue)
                .frame(width: 54, height: 54)
                .background(Palette.ice, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("Follow the models you already have.")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                Text("Let your existing firmware help choose your devices.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button { model.dismissFirmwareSuggestions() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).padding(8)
            .disabled(model.scanningFirmwareModels)
            .accessibilityLabel("Close model suggestions")
        }.padding(28)
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YOUR FIRMWARE FOLDER", systemImage: "folder")
                .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Palette.muted)
            Text(model.firmwareScanFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("RestoreDock identifies models from your IPSWs without changing files. Use Import existing IPSWs to verify the files and add them to your library.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).card()
    }

    private var progressCard: some View {
        HStack(alignment: .top, spacing: 13) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text("Finding your device models…").font(.system(size: 13, weight: .semibold))
                Text(model.firmwareScanProgress.isEmpty ? "Looking for iPhone and iPad firmware in this folder." : model.firmwareScanProgress)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineSpacing(4).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }.padding(20).background(Palette.ice.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 7) {
                Text("The folder couldn’t be scanned.").font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineSpacing(4).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }.padding(20).card()
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("\(model.firmwareSuggestionDevices.count) \(model.firmwareSuggestionDevices.count == 1 ? "MODEL FOUND" : "MODELS FOUND")")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.muted)
                Spacer()
                Button(selectedCount == availableIDs.count ? "Deselect all" : "Select all") {
                    if selectedCount == availableIDs.count {
                        model.selectedFirmwareSuggestionIDs.subtract(availableIDs)
                    } else {
                        model.selectedFirmwareSuggestionIDs.formUnion(availableIDs)
                    }
                }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
            }
            Text("Choose the models you want RestoreDock to follow. One IPSW can support several models.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            LazyVStack(spacing: 10) {
                ForEach(model.firmwareSuggestionDevices) { device in
                    suggestionRow(device)
                }
            }
            Label(model.preferences.automaticDownloads
                  ? "Automatic downloads are on. Following these models will queue their latest firmware."
                  : "Automatic downloads are off. Following models keeps that setting unchanged.",
                  systemImage: model.preferences.automaticDownloads ? "arrow.down.circle" : "info.circle")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        }
    }

    private func suggestionRow(_ device: DeviceFirmware) -> some View {
        let files = model.firmwareScanReport?.files.filter { $0.modelIdentifiers.contains(device.id) } ?? []
        return VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(
                get: { model.selectedFirmwareSuggestionIDs.contains(device.id) },
                set: { selected in
                    if selected { model.selectedFirmwareSuggestionIDs.insert(device.id) }
                    else { model.selectedFirmwareSuggestionIDs.remove(device.id) }
                }
            )) {
                HStack(spacing: 15) {
                    DevicePhotoView(modelIdentifier: device.id, width: 68, height: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name).font(.system(size: 13, weight: .semibold))
                        Text(device.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                        Text("Found in \(files.count) \(files.count == 1 ? "IPSW" : "IPSWs")")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 8)
            }.toggleStyle(.checkbox).accessibilityLabel("Follow \(device.name), \(device.id)")
            DisclosureGroup("Show firmware files") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files, id: \.fileURL) { file in
                        Text(file.fileURL.lastPathComponent)
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 7)
            }.font(.system(size: 10)).padding(.leading, 98)
        }.padding(16).card()
    }

    private func emptyState(scannedFileCount: Int, hasIssues: Bool) -> some View {
        let emptyFolder = scannedFileCount == 0 && !hasIssues
        return VStack(alignment: .leading, spacing: 9) {
            Label(emptyFolder ? "No IPSWs found yet." : "No new models to follow.",
                  systemImage: emptyFolder ? "doc.zipper" : "checkmark.circle")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.blue)
            Text(emptyFolder
                 ? "Add downloaded IPSWs to your firmware folder, then scan again to find their device models."
                 : "There are no additional models available to follow from this scan. Models you already follow are left out of these suggestions.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).card()
    }

    private var unavailableModels: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                Text("These identifiers were found in your firmware but are unavailable in the current device catalog.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                Text(model.unavailableFirmwareModelIDs.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }.padding(.top, 10)
        } label: {
            Label("\(model.unavailableFirmwareModelIDs.count) \(model.unavailableFirmwareModelIDs.count == 1 ? "model" : "models") unavailable", systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium))
        }.padding(18).card()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.scanningFirmwareModels {
                Text("Your files stay in place.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Stop scan") { model.cancelFirmwareModelScan() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button(model.firmwareScanError == nil ? "Scan again" : "Try again") {
                    model.scanFirmwareFolder(manually: true)
                }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Not now") { model.dismissFirmwareSuggestions() }.buttonStyle(SecondaryButtonStyle())
                Button("Follow \(selectedCount) \(selectedCount == 1 ? "model" : "models")") {
                    model.followSelectedFirmwareModels()
                }.buttonStyle(PrimaryButtonStyle()).disabled(selectedCount == 0 || model.firmwareScanError != nil)
            }
        }.padding(.horizontal, 28).padding(.vertical, 19)
    }
}
