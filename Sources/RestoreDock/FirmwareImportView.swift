import SwiftUI
import FirmwareCore

struct FirmwareImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var allowCleanup = false
    @State private var confirmCleanup = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 25)).foregroundStyle(Palette.blue)
                    .frame(width: 54, height: 54).background(Palette.ice, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Bring your firmware along.").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("Verify existing IPSWs and add them to your library.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).padding(8).disabled(model.importing).accessibilityLabel("Close import")
            }.padding(28)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: "checkmark.shield").font(.system(size: 20)).foregroundStyle(Palette.blue)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Same files. No duplicate downloads.").font(.system(size: 13, weight: .semibold))
                            Text("Files stay in their current folders. We read each IPSW’s device information, compare its size and checksum with IPSW.me metadata, and register verified files for reuse. Signed and unsigned public releases can be imported.")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                        }
                    }.padding(20).card()
                    VStack(alignment: .leading, spacing: 15) {
                        Text("CHOOSE YOUR FILES").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
                        HStack(spacing: 10) {
                            Button("Choose IPSWs or folders…") { model.chooseImportFiles() }.buttonStyle(SecondaryButtonStyle())
                            Button("Use Configurator cache") { model.selectConfiguratorImport() }.buttonStyle(SecondaryButtonStyle())
                                .disabled(!model.configuratorDirectoryExists)
                            Spacer()
                        }.disabled(model.importing)
                        if model.importSelections.isEmpty {
                            Text("Select individual files or a folder. Folder searches include subfolders; hidden files and symbolic links are skipped.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.importSelections, id: \.self) { url in
                                    Label(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "doc.zipper")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(2)
                                }
                            }
                        }
                    }.padding(20).card()
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Include these imports in automatic cleanup", isOn: Binding(get: { allowCleanup }, set: { enabled in
                            if enabled { confirmCleanup = true } else { allowCleanup = false }
                        })).toggleStyle(.switch).font(.system(size: 12, weight: .medium)).disabled(model.importing)
                        Text(allowCleanup
                             ? "If Automatic Cleanup is enabled in Settings, these imported files may be permanently deleted from their current folders when reported unsigned. "
                             : "Off by default. Newly imported files are protected from automatic deletion, even when Automatic Cleanup is enabled in Settings.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                        Text("Already registered files keep their existing cleanup permission.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(20).card()
                    if model.importing || !model.importProgress.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            if model.importing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "info.circle").foregroundStyle(Palette.blue) }
                            Text(model.importProgress).font(.system(size: 12, weight: .medium)).textSelection(.enabled).lineSpacing(4)
                            Spacer()
                        }.padding(18).background(Palette.ice.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !model.importResults.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("IMPORT RESULTS").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
                            ForEach(model.importResults) { result in
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .foregroundStyle(result.succeeded ? Palette.blue : Color.orange)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(result.file.lastPathComponent).font(.system(size: 12, weight: .medium))
                                        Text(result.message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    }.textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }.padding(20).card()
                    }
                    Text("Verification reads the whole file and may take a few minutes for large IPSWs. Unrecognized, incomplete, or changed files are skipped. No firmware is downloaded during import.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                }.padding(28)
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 12) {
                if model.cleaningUp || model.previewingCleanup {
                    Text("Wait for the current cleanup check to finish.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    Text("Your originals stay where they are.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if model.importing {
                    Button("Stop import") { model.cancelImport() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button("Verify & import") { model.startImport(allowAutomaticCleanup: allowCleanup) }.buttonStyle(PrimaryButtonStyle())
                        .disabled(model.importSelections.isEmpty || model.cleaningUp || model.previewingCleanup)
                }
            }.padding(.horizontal, 28).padding(.vertical, 19)
        }.frame(width: 780, height: 720).background(Palette.canvas).foregroundStyle(Palette.ink).tint(Palette.blue)
            .interactiveDismissDisabled(model.importing)
            .confirmationDialog("Allow automatic deletion of these imports?", isPresented: $confirmCleanup, titleVisibility: .visible) {
                Button("Allow automatic cleanup", role: .destructive) { allowCleanup = true }
                Button("Keep imports protected", role: .cancel) { allowCleanup = false }
            } message: {
                Text("When Automatic Cleanup is enabled, verified imports reported unsigned may be permanently deleted from their original folders. This bypasses Trash and cannot be undone. Importing itself does not delete or move files.")
            }
    }
}
