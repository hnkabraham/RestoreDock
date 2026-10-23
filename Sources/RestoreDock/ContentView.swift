import AppKit
import FirmwareCore
import SwiftUI

enum Palette {
    static let ink = Color(red: 11 / 255, green: 35 / 255, blue: 67 / 255)
    static let muted = Color(red: 83 / 255, green: 104 / 255, blue: 128 / 255)
    static let blue = Color(red: 0, green: 93 / 255, blue: 170 / 255)
    static let ice = Color(red: 219 / 255, green: 239 / 255, blue: 255 / 255)
    static let sky = Color(red: 90 / 255, green: 176 / 255, blue: 229 / 255)
    static let canvas = Color(red: 246 / 255, green: 249 / 255, blue: 253 / 255)
    static let line = Color(red: 216 / 255, green: 227 / 255, blue: 238 / 255)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var inspectedDevice: DeviceFirmware?
    @State private var confirmAutomaticCleanup = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 226)
            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.line)
                if let message = model.errorMessage ?? model.downloads.persistenceError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(message).textSelection(.enabled)
                        Spacer()
                        if model.errorMessage != nil { Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    }.font(.system(size: 12)).foregroundStyle(Color(red: 0.54, green: 0.28, blue: 0.08)).padding(14).background(Color.orange.opacity(0.09))
                }
                Group {
                    switch model.screen {
                    case .library: overview
                    case .devices: devices
                    case .downloads: downloadScreen
                    case .storage: StorageView().environmentObject(model)
                    case .settings: settings
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Palette.canvas)
        }.foregroundStyle(Palette.ink).tint(Palette.blue)
            .sheet(item: $inspectedDevice) { device in
                DeviceDetailView(device: device).environmentObject(model)
            }
            .sheet(isPresented: $model.showImport) { FirmwareImportView().environmentObject(model) }
            .confirmationDialog("Enable automatic deletion?", isPresented: $confirmAutomaticCleanup, titleVisibility: .visible) {
                Button("Enable automatic deletion", role: .destructive) { model.setAutomaticCleanup(true) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("RestoreDock will permanently delete its completed IPSWs when fresh signing data reports them unsigned for every linked model. This frees space without using Trash and cannot be undone. Files with unknown signing status are kept.")
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 24)).foregroundStyle(Palette.ice)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore").font(.system(size: 19, weight: .semibold))
                    Text("D O C K").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }.padding(.bottom, 38).padding(.top, 50).padding(.horizontal, 26)
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.35)).padding(.horizontal, 26).padding(.bottom, 13)
            ForEach(Screen.allCases) { screen in
                Button { model.screen = screen } label: {
                    HStack(spacing: 12) {
                        Image(systemName: screen.icon).font(.system(size: 16)).frame(width: 21)
                        Text(screen.rawValue).font(.system(size: 13, weight: model.screen == screen ? .semibold : .medium))
                        Spacer()
                        if screen == .downloads && !model.pendingItems.isEmpty {
                            Text("\(model.pendingItems.count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule())
                        }
                    }.padding(.horizontal, 15).padding(.vertical, 13)
                        .foregroundStyle(model.screen == screen ? Palette.ice : .white.opacity(0.65))
                        .background(model.screen == screen ? Palette.blue.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(model.preferences.automaticDownloads ? Palette.ice : .white.opacity(0.3)).frame(width: 6, height: 6)
                    Text(model.preferences.automaticDownloads ? "Automatic downloads on" : "Automatic downloads off").font(.system(size: 11, weight: .medium))
                }.foregroundStyle(.white.opacity(0.85))
                Text("A home for\nrestore-ready firmware.").font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.4))
                Button { model.revealLibrary() } label: {
                    Label("Open firmware folder", systemImage: "folder").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Palette.ice)
            }.padding(21).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).padding(14)
            Text("RESTOREDOCK  /  1.6").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 26).padding(.bottom, 20)
        }.background(Palette.ink).foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Workspace").foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.muted.opacity(0.6))
                Text(model.screen.rawValue).fontWeight(.medium)
            }.font(.system(size: 12))
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small); Text("Checking Apple…").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            else if let date = model.catalog?.fetchedAt {
                Text("Checked \(date, style: .relative) ago").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.plain).padding(8).background(.white, in: Circle()).disabled(model.refreshing).help("Check Apple for new firmware (⌘R)")
        }.padding(.horizontal, 30).padding(.top, 23).padding(.bottom, 19)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                title("Ready for the next restore.", subtitle: "Fresh firmware. Organized by device. Downloaded from Apple.")
                hero
                HStack(spacing: 14) {
                    MetricCard(value: "\(model.trackedDevices.count)", title: "Models followed", detail: model.preferences.allSupported ? "All supported devices" : "Your selected iPhones & iPads", icon: "ipad.and.iphone")
                    MetricCard(value: "\(model.readyItems.count)", title: "IPSWs ready", detail: "\(byteString(model.librarySize)) in your library", icon: "checkmark.seal")
                    MetricCard(value: model.availableBytes.map(byteString) ?? "—", title: "Space available", detail: "\(model.preferences.reserveGB) GB kept free", icon: "externaldrive")
                }
                HStack {
                    Text("In your library").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("View downloads →") { model.screen = .downloads }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.blue)
                }.padding(.top, 3)
                if model.readyItems.isEmpty {
                    VStack(spacing: 13) {
                        Image(systemName: "tray.2").font(.system(size: 29, weight: .light)).foregroundStyle(Palette.blue.opacity(0.7))
                        Text("A place for every restore.").font(.system(size: 16, weight: .semibold))
                        Text(model.trackedDevices.isEmpty ? "Choose the devices you work with. We’ll keep their latest\npublic firmware ready whenever you need it." : "Your verified downloads will appear here, ready to reveal in Finder.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                        Button(model.trackedDevices.isEmpty ? "Choose devices" : "Download selected firmware") {
                            if model.trackedDevices.isEmpty { model.screen = .devices } else { model.enqueueTracked(); model.screen = .downloads }
                        }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                    }.frame(maxWidth: .infinity).padding(.vertical, 32).card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.readyItems.prefix(5).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 70) }
                            DownloadRow(item: item).environmentObject(model)
                        }
                    }.card()
                }
                Label("IPSW files come directly from Apple. Checksums are verified before a file is marked ready.", systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                catalogWarnings
            }.padding(30)
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 13) {
                Label("YOUR FIRMWARE, ON AUTOPILOT", systemImage: "sparkle").font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(Palette.ice)
                Text(model.preferences.automaticDownloads ? "One less thing\non your workbench." : "Set it once.\nStay ready.").font(.system(size: 29, weight: .semibold)).tracking(-0.7).lineSpacing(2).foregroundStyle(.white)
                Text(model.preferences.automaticDownloads ? "Watching \(model.trackedDevices.count) models. New public releases\njoin your download queue automatically." : "Pick your models and turn on automatic downloads.\nWe’ll watch for the next public release.")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(.white.opacity(0.67))
                Button {
                    if model.trackedDevices.isEmpty { model.screen = .devices }
                    else { model.setAutomatic(!model.preferences.automaticDownloads) }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.trackedDevices.isEmpty ? "Choose your devices" : model.preferences.automaticDownloads ? "Turn off automatic downloads" : "Enable automatic downloads")
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(Palette.ink).background(Palette.ice, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.top, 4)
            }
            Spacer(minLength: 5)
            ZStack {
                Circle().stroke(.white.opacity(0.06), lineWidth: 1).frame(width: 215, height: 215)
                Circle().stroke(.white.opacity(0.07), lineWidth: 1).frame(width: 160, height: 160)
                RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.07)).frame(width: 132, height: 165).rotationEffect(.degrees(-11)).offset(x: -20, y: 5)
                RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.18)).frame(width: 132, height: 165).rotationEffect(.degrees(7)).offset(x: 5, y: -3)
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 34, weight: .light))
                    Text(".ipsw").font(.system(size: 20, weight: .medium, design: .monospaced))
                    HStack(spacing: 5) { Circle().fill(Palette.ice).frame(width: 5, height: 5); Text("RESTORE READY").font(.system(size: 6, weight: .semibold)).tracking(1.4) }
                }.foregroundStyle(Palette.ice).rotationEffect(.degrees(7)).offset(x: 5, y: -3)
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink).frame(width: 37, height: 37).background(Palette.ice, in: Circle()).overlay(Circle().stroke(Palette.ink, lineWidth: 5)).offset(x: 73, y: 70)
            }.frame(width: 225, height: 220).accessibilityHidden(true)
        }.padding(.horizontal, 30).padding(.vertical, 26)
            .background(LinearGradient(colors: [Palette.ink, Palette.blue], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Make it your fleet.", subtitle: "Follow individual models, or automatically include every supported device.")
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All supported iPhones & iPads").font(.system(size: 14, weight: .semibold))
                    Text("Includes new models as Apple adds them. Older devices with public security releases are included.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("All supported devices", isOn: Binding(get: { model.preferences.allSupported }, set: model.selectAll)).labelsHidden().toggleStyle(.switch)
            }.padding(20).card()
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Find a model or identifier…", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }.buttonStyle(.plain) }
                }.font(.system(size: 12)).padding(11).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                Picker("Device family", selection: $model.family) {
                    Text("All devices").tag("All devices"); Text("iPhone").tag("iPhone"); Text("iPad").tag("iPad")
                }.labelsHidden().frame(width: 130)
            }
            HStack {
                Text("\(model.filteredDevices.count) MODELS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(model.trackedDevices.count) selected · \(model.uniqueTrackedCount) unique IPSWs").font(.system(size: 11)).foregroundStyle(Palette.blue)
            }
            if model.allDevices.isEmpty {
                emptyCatalog
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(model.filteredDevices) { device in deviceRow(device) }
                    }.padding(.bottom, 4)
                }
                if model.filteredDevices.isEmpty { Text("No models match your search.").foregroundStyle(Palette.muted).frame(maxWidth: .infinity) }
            }
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.preferences.automaticDownloads ? "New releases download automatically" : "Ready when you are").font(.system(size: 12, weight: .semibold))
                    Text("Shared files download once. Unfollowing a model leaves its existing queue entries in place.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(model.preferences.automaticDownloads ? "Download now" : "Enable auto downloads") {
                    if model.preferences.automaticDownloads { model.enqueueTracked() }
                    else { model.setAutomatic(true) }
                    model.screen = .downloads
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.trackedDevices.isEmpty)
            }.padding(17).card()
        }.padding(30)
    }

    private func deviceRow(_ device: DeviceFirmware) -> some View {
        HStack(spacing: 15) {
            Button { inspectedDevice = device } label: {
                HStack(spacing: 15) {
                    DevicePhotoView(modelIdentifier: device.id)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name).font(.system(size: 13, weight: .semibold))
                        Text(device.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        Text("Release history & Apple’s notes").font(.system(size: 10)).foregroundStyle(Palette.blue)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(device.id.hasPrefix("iPad") ? "iPadOS" : "iOS") \(device.version)").font(.system(size: 11, weight: .medium))
                        Text(device.build).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.blue).padding(.trailing, 5)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("View release history for \(device.name)")
            Toggle("Follow \(device.name)", isOn: Binding(get: { model.isTracked(device.id) }, set: { model.setTracked(device.id, value: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(13).card()
    }

    private var downloadScreen: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                title("Good things in the queue.", subtitle: "One download at a time, with verification before every file enters your library.")
                Spacer()
                Button(model.downloads.isPaused ? "Resume" : "Pause queue") {
                    if model.downloads.isPaused { model.downloads.resume() } else { model.downloads.pause() }
                }.buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 20) {
                Label("\(model.pendingItems.count) in queue", systemImage: "arrow.down.circle")
                Label("\(model.readyItems.count) ready", systemImage: "checkmark.circle")
                Spacer()
                Button("Import IPSWs…") { model.showImport = true }.buttonStyle(.plain).foregroundStyle(Palette.blue)
                Button("Add selected models") { model.enqueueTracked() }.buttonStyle(.plain).foregroundStyle(Palette.blue).disabled(model.trackedDevices.isEmpty)
            }.font(.system(size: 12)).padding(18).card()
            if model.downloads.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.to.line.compact").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Palette.blue)
                    Text("Your queue is clear.").font(.system(size: 20, weight: .semibold))
                    Text("Choose your devices to get your firmware library started.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Choose devices") { model.screen = .devices }.buttonStyle(PrimaryButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.pendingItems + model.readyItems) { item in DownloadRow(item: item).environmentObject(model).card() }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text((model.preferences.destinationPath as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open in Finder") { model.revealLibrary() }.buttonStyle(.plain).foregroundStyle(Palette.blue)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(30)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                title("A little setup. A lot less upkeep.", subtitle: "Make RestoreDock fit your workbench.")
                settingsGroup("AUTOMATION") {
                    settingRow("Automatically download new releases", detail: "Queue new public IPSWs for followed models. Turning this off leaves the existing queue running; pause it in Downloads.") {
                        Toggle("Automatic downloads", isOn: Binding(get: { model.preferences.automaticDownloads }, set: model.setAutomatic)).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    settingRow("Check for new firmware", detail: "Checks run while the app is open and your Mac is awake.") {
                        Picker("Check interval", selection: $model.preferences.intervalHours) {
                            Text("Every hour").tag(1); Text("Every 3 hours").tag(3); Text("Every 6 hours").tag(6); Text("Every 12 hours").tag(12); Text("Daily").tag(24)
                        }.labelsHidden().frame(width: 145)
                    }
                    Divider()
                    settingRow("Open at login", detail: "Keep the app running in the menu bar after you sign in.") {
                        Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLaunchAtLogin)).labelsHidden().toggleStyle(.switch)
                    }
                    if model.loginNeedsApproval { Text("Allow RestoreDock in System Settings → General → Login Items.").font(.system(size: 11)).foregroundStyle(.orange) }
                    Divider()
                    settingRow("Notify when firmware is ready", detail: "A notification after a download passes verification.") {
                        Toggle("Ready notifications", isOn: Binding(get: { model.preferences.notifications }, set: model.setNotifications)).labelsHidden().toggleStyle(.switch)
                    }
                }
                settingsGroup("STORAGE") {
                    settingRow("Firmware library", detail: (model.preferences.destinationPath as NSString).abbreviatingWithTildeInPath) { Button("Choose folder…") { model.chooseFolder() }.buttonStyle(SecondaryButtonStyle()) }
                    Text("Folder changes apply to downloads that haven’t started. Started and completed downloads keep their original folder.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Divider()
                    settingRow("Apple Configurator firmware cache", detail: model.isUsingConfiguratorDirectory && model.configuratorDirectoryExists ? "Your downloads are saved to Configurator’s firmware folder." : model.configuratorDirectoryExists ? "This Mac already has a Configurator firmware folder. Use it for new downloads." : "The cache folder isn’t here yet. Create it and use it for new downloads.") {
                        if model.isUsingConfiguratorDirectory && model.configuratorDirectoryExists {
                            Label("In use", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
                        } else {
                            Button(model.configuratorDirectoryExists ? "Use Configurator folder" : "Create & use folder") {
                                model.useConfiguratorDirectory(createIfNeeded: !model.configuratorDirectoryExists)
                            }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Text(model.configuratorDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).lineSpacing(3)
                    Text("New setups use this folder automatically when it exists. Configurator manages its cache and may remove files. You can also drag a matching IPSW onto a selected device in Configurator.").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
                    Divider()
                    settingRow("Keep free space", detail: "Stop new transfers before they use this disk reserve. Downloads also need temporary space on the Mac’s internal disk.") {
                        Picker("Free space reserve", selection: Binding(get: { model.preferences.reserveGB }, set: model.setReserve)) {
                            ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                        }.labelsHidden().frame(width: 120)
                    }
                    Divider()
                    settingRow("Downloaded files", detail: "See usage by model and version, import existing IPSWs, and preview automatic cleanup.") {
                        Button("View storage") { model.screen = .storage }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                settingsGroup("AUTOMATIC CLEANUP") {
                    settingRow("Automatically delete unsigned IPSWs", detail: "Permanently remove completed downloads when they’re no longer reported as signed. Deletion bypasses Trash and cannot be undone.") {
                        Toggle("Automatically delete unsigned IPSWs", isOn: Binding(get: { model.preferences.automaticallyDeleteUnsigned }, set: { enabled in
                            if enabled { confirmAutomaticCleanup = true }
                            else { model.setAutomaticCleanup(false) }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    Text("Checks IPSW.me every \(model.preferences.intervalHours) hours while the app is open and your Mac is awake. Only verified downloads and imports explicitly allowed for cleanup are eligible. Shared IPSWs are kept while any linked model is still signed; missing, conflicting, or unavailable signing data leaves files untouched.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                    Divider()
                    HStack(spacing: 16) {
                        if model.cleaningUp { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.cleaningUp ? model.cleanupProgress : cleanupSummary).font(.system(size: 12, weight: .medium))
                            if let report = model.cleanupReport {
                                Text("Last check: \(report.date.formatted(date: .abbreviated, time: .shortened)) · \(report.checkedCount) checked · \(report.skippedCount) skipped")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            } else {
                                Text(model.preferences.automaticallyDeleteUnsigned ? "Cleanup runs independently of automatic downloads." : "Off by default. Your completed downloads are kept.")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Check & clean now") { model.startCleanup() }.buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.preferences.automaticallyDeleteUnsigned || model.cleaningUp)
                    }
                    Button("Preview eligible files in Storage →") { model.screen = .storage; model.previewCleanup() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
                    if let warnings = model.cleanupReport?.warnings, !warnings.isEmpty {
                        DisclosureGroup("Cleanup notes (\(warnings.count))") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in Text(warning).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            }.padding(.top, 8)
                        }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                settingsGroup("SOURCES & RESTORING") {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("Current release metadata & checksums: Apple’s restore catalog", systemImage: "checkmark.shield")
                        Label("Supported releases: Apple Software Lookup Service", systemImage: "server.rack")
                        Label("History metadata, checksums, model names & photos: IPSW.me", systemImage: "ipad.and.iphone")
                        Label("Release notes: Apple Support", systemImage: "doc.text")
                        Link("View original device photos on IPSW.me ↗", destination: URL(string: "https://ipsw.me/product/iPhone/")!).foregroundStyle(Palette.blue)
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Divider()
                    Text("To restore, connect the device, select it in Finder, hold Option, and click Restore iPhone or Restore iPad. Choose a matching IPSW from your library. Restoring erases the device; Finder and Apple handle restore authorization.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).textSelection(.enabled)
                    Text("RestoreDock downloads public releases only. It does not install firmware or access connected devices.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                catalogWarnings
            }.padding(30)
        }.onAppear { model.refreshLoginStatus() }
    }

    private var cleanupSummary: String {
        guard let report = model.cleanupReport else { return "No cleanup check yet" }
        if report.removedCount > 0 { return "\(report.removedCount) IPSW\(report.removedCount == 1 ? "" : "s") deleted · \(byteString(report.reclaimedBytes)) removed" }
        if report.skippedCount > 0 || !report.warnings.isEmpty { return "No files deleted. See cleanup notes below." }
        return report.checkedCount == 0 ? "No completed downloads to check" : "Your downloaded IPSWs are still signed"
    }

    private var emptyCatalog: some View {
        VStack(spacing: 17) {
            if model.refreshing { ProgressView(); Text("Reading Apple’s firmware catalogs…") }
            else {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text("The firmware catalog isn’t available yet.")
                Button("Try again") { Task { await model.refresh() } }.buttonStyle(PrimaryButtonStyle())
            }
        }.font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var catalogWarnings: some View {
        if let warnings = model.catalog?.warnings, !warnings.isEmpty {
            DisclosureGroup("Catalog notes (\(warnings.count))") {
                VStack(alignment: .leading, spacing: 7) { ForEach(warnings, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 10)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(16).card()
        }
    }
    private func title(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.7)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
            content()
        }.padding(22).card()
    }
    private func settingRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            control().fixedSize()
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject var model: AppModel
    let item: DownloadItem
    private var statusColor: Color { item.status == .ready ? Palette.blue : item.status == .failed ? .orange : Palette.muted }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DevicePhotoView(modelIdentifier: item.modelIdentifiers.first ?? "", width: 72, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(item.name).font(.system(size: 13, weight: .semibold)); Text(item.version).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Text(item.modelIdentifiers.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(2)
                if item.status == .downloading || item.status == .verifying {
                    if item.status == .verifying { ProgressView().controlSize(.small) }
                    else { ProgressView(value: item.expectedBytes.map { min(1, Double(item.downloadedBytes) / Double(max(1, $0))) } ?? 0).tint(Palette.blue) }
                    Text(item.status == .verifying ? "Verifying firmware checksum…" : "\(byteString(item.downloadedBytes))\(item.expectedBytes.map { " of \(byteString($0))" } ?? " downloaded")").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                if let error = item.errorMessage { Text(error).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3) }
            }
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 9) {
                Text(item.status.rawValue.capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor).padding(.horizontal, 9).padding(.vertical, 5).background(statusColor.opacity(0.07), in: Capsule())
                if item.status == .ready {
                    Button("Show in Finder") { model.reveal(item) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.blue)
                } else if item.status == .failed {
                    Button("Retry") { model.downloads.retry(item.id) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.blue)
                }
            }
            Menu {
                if item.status == .ready { Button("Show in Finder") { model.reveal(item) } }
                if item.status == .failed { Button("Retry download") { model.downloads.retry(item.id) } }
                Button(item.status == .ready ? "Forget entry (keep file)" : "Remove from queue") { model.downloads.remove(item.id, deleteFile: false) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 19)
        }.padding(17)
    }
}

struct MetricCard: View {
    let value: String
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted); Spacer(); Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Palette.blue) }
            Text(value).font(.system(size: 27, weight: .semibold)).tracking(-0.7).lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11).background(Palette.blue.opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink).padding(.horizontal, 13).padding(.vertical, 9).background(Color.white.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line)).opacity(isEnabled ? 1 : 0.4)
    }
}
extension View {
    func card() -> some View { background(.white, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line)) }
}
