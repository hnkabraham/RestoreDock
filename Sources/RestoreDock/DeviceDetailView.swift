import AppKit
import FirmwareCore
import SwiftUI
import WebKit

struct DeviceDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let device: DeviceFirmware
    @State private var history: FirmwareHistory?
    @State private var selectedID: String?
    @State private var filter = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var checkingBuild: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadFeedback: DownloadFeedback?
    @State private var downloadAlert: String?

    private struct DownloadFeedback {
        let build: String
        let message: String
        let isError: Bool
    }

    private var selectedRelease: FirmwareRelease? {
        history?.releases.first { $0.id == selectedID } ?? history?.releases.first
    }
    private var visibleReleases: [FirmwareRelease] {
        (history?.releases ?? []).filter { filter.isEmpty || $0.version.localizedCaseInsensitiveContains(filter) || $0.build.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 19) {
                DevicePhotoView(modelIdentifier: device.id, width: 83, height: 85)
                VStack(alignment: .leading, spacing: 7) {
                    Text("DEVICE LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.blue)
                    Text(device.name).font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                    Text(device.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Follow model", isOn: Binding(get: { model.isTracked(device.id) }, set: { model.setTracked(device.id, value: $0) }))
                    .toggleStyle(.switch).font(.system(size: 11)).fixedSize()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).padding(10).background(Palette.canvas, in: Circle()) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close device history").padding(.leading, 12)
            }.padding(.horizontal, 26).padding(.vertical, 18).background(.white)
            Divider().overlay(Palette.line)
            HStack(spacing: 0) {
                releaseList.frame(width: 292)
                Divider().overlay(Palette.line)
                if let release = selectedRelease {
                    releaseDetail(release)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.blue)
                        Text(loading ? "Fetching this model’s release history…" : "Select a release to see Apple’s notes.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("Signing status comes from IPSW.me and is checked again before queuing. Apple makes the final restore decision.")
                Spacer()
                if let history { Text(history.fetchedAt, style: .time).foregroundStyle(Palette.muted) }
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 23).padding(.vertical, 13).background(.white)
        }.frame(width: 1030, height: 714).background(Palette.canvas).foregroundStyle(Palette.ink).tint(Palette.blue)
            .task(id: device.id) { await loadHistory() }
            .onDisappear { downloadTask?.cancel() }
            .alert("Download not added", isPresented: Binding(get: { downloadAlert != nil }, set: { if !$0 { downloadAlert = nil } })) {
                Button("OK", role: .cancel) { downloadAlert = nil }
            } message: { Text(downloadAlert ?? "") }
    }

    private var releaseList: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Release history").font(.system(size: 17, weight: .semibold))
                    Text(history.map { "\($0.releases.count) public IPSW releases" } ?? "Public restore images for this model").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { Task { await loadHistory() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(loading || checkingBuild != nil).help("Refresh release history")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("Version or build…", text: $filter).textFieldStyle(.plain)
            }.font(.system(size: 11)).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
            if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(10) }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("History unavailable", systemImage: "wifi.exclamationmark").font(.system(size: 12, weight: .medium))
                    Text(errorMessage).font(.system(size: 11)).textSelection(.enabled)
                    Button("Try again") { Task { await loadHistory() } }.buttonStyle(SecondaryButtonStyle()).disabled(loading)
                }.foregroundStyle(Palette.muted).padding(13).card()
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleReleases) { release in
                        Button { selectedID = release.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("\(osName(release.version)) \(release.version)").font(.system(size: 12, weight: .semibold))
                                    Spacer(minLength: 4)
                                    Circle().fill(release.isSigningStatusConflicting ? Color.orange : release.isSigned ? Palette.blue : Palette.muted.opacity(0.3)).frame(width: 6, height: 6)
                                }
                                HStack {
                                    Text(release.build).font(.system(size: 10, design: .monospaced))
                                    Spacer()
                                    if let date = release.releaseDate { Text(date, format: .dateTime.month(.abbreviated).day().year()).font(.system(size: 10)) }
                                }.foregroundStyle(Palette.muted)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedRelease?.id == release.id ? Palette.ice : Color.white, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedRelease?.id == release.id ? Palette.blue.opacity(0.5) : Palette.line))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(osName(release.version)) \(release.version), build \(release.build), \(signingStatus(release).lowercased())")
                    }
                    if history != nil && visibleReleases.isEmpty {
                        Text(filter.isEmpty ? "No public IPSW history was found." : "No matching releases.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 20)
                    }
                }.padding(.bottom, 3)
            }
            Link("History provided by IPSW.me ↗", destination: URL(string: "https://ipsw.me/\(device.id)")!)
                .font(.system(size: 10)).foregroundStyle(Palette.blue)
        }.padding(18).background(Palette.canvas)
    }

    private func releaseDetail(_ release: FirmwareRelease) -> some View {
        let notesURL = AppleReleaseNotes.url(deviceIdentifier: device.id, version: release.version)
        let directArticle = AppleReleaseNotes.isDirectArticle(deviceIdentifier: device.id, version: release.version)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(osName(release.version)) \(release.version)").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                        HStack(spacing: 9) {
                            Text("Build \(release.build)")
                            if let size = release.fileSize { Text("·"); Text(byteString(size)) }
                            if let date = release.releaseDate { Text("·"); Text(date, format: .dateTime.month(.abbreviated).day().year()) }
                        }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Label(signingStatus(release), systemImage: release.isSigningStatusConflicting ? "questionmark.circle" : release.isSigned ? "checkmark.seal" : "minus.circle")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(release.isSigned ? Palette.blue : Palette.muted)
                        .padding(.horizontal, 10).padding(.vertical, 7).background(release.isSigned ? Palette.ice : Palette.canvas, in: Capsule())
                }
                downloadControls(for: release)
                HStack {
                    Label("Apple’s release notes", systemImage: "doc.text").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Link("Open in browser ↗", destination: notesURL).font(.system(size: 11)).foregroundStyle(Palette.blue)
                }
                Text(directArticle ? "Apple groups updates on one page for each major version. The matching section is shown when available." : "Apple’s notes for this version are available through its support search.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }.padding(22).background(.white)
            Divider().overlay(Palette.line)
            AppleNotesView(url: notesURL, version: release.version, osName: osName(release.version))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func signingStatus(_ release: FirmwareRelease) -> String {
        release.isSigningStatusConflicting ? "Unknown" : release.isSigned ? "Signed" : "Unsigned"
    }

    private func osName(_ version: String) -> String {
        device.id.hasPrefix("iPad") && (Int(version.split(separator: ".").first ?? "0") ?? 0) >= 13 ? "iPadOS" : "iOS"
    }

    private func queuedItem(for release: FirmwareRelease) -> DownloadItem? {
        guard let url = release.downloadURL else { return nil }
        let id = DownloadManager.identifier(for: url)
        return model.downloads.items.first { $0.id == id }
    }

    @ViewBuilder private func downloadControls(for release: FirmwareRelease) -> some View {
        let item = queuedItem(for: release)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    if let item, item.status == .ready, model.downloads.localURL(for: item) != nil {
                        Label("In your library", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.blue)
                        Text("Verified and ready in your firmware library.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    } else if let item, [.queued, .downloading, .paused, .verifying].contains(item.status) {
                        Label(item.status == .paused ? "In your paused queue" : item.status == .downloading ? "Downloading from Apple" : item.status == .verifying ? "Verifying download" : "In your download queue", systemImage: "arrow.down.circle").foregroundStyle(Palette.blue)
                        Text(item.status == .paused ? "Resume the queue in Downloads when you’re ready." : "Follow progress in Downloads.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    } else if let item, item.status == .failed {
                        Label("Download failed", systemImage: "exclamationmark.circle").foregroundStyle(Color.orange)
                        Text(release.canDownload ? "Signing is checked again before a retry." : "This release is no longer eligible for a new download.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    } else if release.canDownload {
                        Text("Download this release").foregroundStyle(Palette.ink)
                        Text("Uses your firmware folder. Signing is checked before queuing.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    } else {
                        Text(release.isSigningStatusConflicting ? "Signing status unknown" : release.isSigned ? "Download metadata unavailable" : "No longer signed").foregroundStyle(Palette.muted)
                        Text(release.isSigningStatusConflicting ? "The signing data conflicts. Refresh history and try again later." : release.isSigned ? "A valid Apple download link and checksum are required." : "Downloads are available for releases still reported as signed.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }.font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if let item, item.status == .ready, model.downloads.localURL(for: item) != nil {
                    Button("Show in Finder") { model.reveal(item) }.buttonStyle(SecondaryButtonStyle())
                } else if let item, [.queued, .downloading, .paused, .verifying].contains(item.status) {
                    Button("View download") { model.screen = .downloads; dismiss() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button {
                        downloadTask = Task { await download(release) }
                    } label: {
                        HStack(spacing: 7) {
                            if checkingBuild == release.build { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.down.to.line") }
                            Text(checkingBuild == release.build ? "Checking signing…" : item?.status == .failed ? "Retry download" : "Download IPSW")
                        }
                    }.buttonStyle(PrimaryButtonStyle())
                        .disabled(!release.canDownload || loading || checkingBuild != nil)
                }
            }
            if let item, item.status == .failed {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.errorMessage ?? "The transfer couldn’t complete.").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("View download") { model.screen = .downloads; dismiss() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.blue).fixedSize()
                }
            }
            if let feedback = downloadFeedback, feedback.build == release.build {
                Text(feedback.message).font(.system(size: 11)).foregroundStyle(feedback.isError ? Color.orange : Palette.blue).textSelection(.enabled)
            }
        }.padding(13).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
    }

    @MainActor private func download(_ release: FirmwareRelease) async {
        guard release.canDownload, checkingBuild == nil, !loading else { return }
        checkingBuild = release.build
        downloadFeedback = nil
        defer { checkingBuild = nil }
        do {
            // Re-fetch for this model and exact build so a stale history screen
            // cannot queue a release that has since been marked unsigned.
            let freshHistory = try await FirmwareHistoryService().fetch(deviceIdentifier: device.id)
            try Task.checkCancellation()
            history = freshHistory
            errorMessage = nil
            guard let current = freshHistory.releases.first(where: { $0.build == release.build && $0.version == release.version }) else {
                downloadAlert = "\(osName(release.version)) \(release.version) (\(release.build)) is no longer listed for this model. Nothing was queued."
                return
            }
            guard !current.isSigningStatusConflicting else {
                downloadFeedback = DownloadFeedback(build: release.build, message: "Signing data conflicts. Nothing was queued. Try refreshing later.", isError: true)
                return
            }
            guard current.isSigned else {
                downloadFeedback = DownloadFeedback(build: release.build, message: "This release is no longer reported as signed. Nothing was queued.", isError: true)
                return
            }
            guard let firmware = current.firmware(deviceIdentifier: device.id, name: device.name) else {
                downloadFeedback = DownloadFeedback(build: release.build, message: "A valid Apple download link and checksum are unavailable. Nothing was queued.", isError: true)
                return
            }
            let retryExisting = queuedItem(for: current)?.status == .failed
            model.downloads.enqueue([firmware])
            if retryExisting, let item = queuedItem(for: current), item.status == .failed { model.downloads.retry(item.id) }
        } catch is CancellationError {
            // Closing the sheet cancels a signing check before anything is queued.
        } catch {
            if !Task.isCancelled {
                downloadFeedback = DownloadFeedback(build: release.build, message: "Couldn’t check signing status. Nothing was queued. \(error.localizedDescription)", isError: true)
            }
        }
    }

    @MainActor private func loadHistory() async {
        guard !loading, checkingBuild == nil else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let result = try await FirmwareHistoryService().fetch(deviceIdentifier: device.id)
            guard !Task.isCancelled else { return }
            history = result
            if !result.releases.contains(where: { $0.id == selectedID }) { selectedID = result.releases.first?.id }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private struct AppleNotesView: View {
    let url: URL
    let version: String
    let osName: String
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            AppleNotesWebView(url: url, version: version, osName: osName, loading: $loading, errorMessage: $errorMessage)
                .id(reloadID)
            if loading { ProgressView().controlSize(.small).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(12) }
            if let errorMessage {
                VStack(spacing: 13) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .light))
                    Text("Apple’s page couldn’t load.").font(.system(size: 16, weight: .semibold))
                    Text(errorMessage).font(.system(size: 11)).multilineTextAlignment(.center).textSelection(.enabled)
                    HStack(spacing: 15) {
                        Button("Try again") { reloadID = UUID() }.buttonStyle(SecondaryButtonStyle())
                        Link("Open in browser ↗", destination: url).font(.system(size: 12))
                    }
                }.foregroundStyle(Palette.muted).padding(35).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
            }
        }.background(.white)
    }
}

private struct AppleNotesWebView: NSViewRepresentable {
    let url: URL
    let version: String
    let osName: String
    @Binding var loading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.selectedVersion = version
            webView.load(URLRequest(url: url, timeoutInterval: 40))
        } else if context.coordinator.selectedVersion != version {
            context.coordinator.selectedVersion = version
            context.coordinator.scrollToRelease(webView)
        }
    }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AppleNotesWebView
        var loadedURL: URL?
        var selectedVersion = ""
        init(_ parent: AppleNotesWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.errorMessage = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            scrollToRelease(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.loading = false
            parent.errorMessage = error.localizedDescription
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.loading = false
            parent.errorMessage = "The page closed unexpectedly. Try loading it again."
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let host = url.host?.lowercased() ?? ""
            let isApple = url.scheme == "https" && (host == "apple.com" || host.hasSuffix(".apple.com"))
            let isSamePage = url.host == webView.url?.host && url.path == webView.url?.path && url.query == webView.url?.query
            if isApple && action.targetFrame != nil && (action.navigationType != .linkActivated || isSamePage) { decisionHandler(.allow) }
            else {
                if action.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
        func scrollToRelease(_ webView: WKWebView) {
            // Apple maintains one article per major OS. Jump to an exact heading
            // without changing the article's content or relying on unstable IDs.
            let components = parent.version.split(separator: ".")
            let articleVersion = components.count == 2 && components[1] == "0" ? String(components[0]) : parent.version
            let targets = ["\(parent.osName) \(parent.version)", "\(parent.osName) \(articleVersion)"]
            guard let data = try? JSONSerialization.data(withJSONObject: targets), let encoded = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("""
            (() => {
                const targets = \(encoded);
                const heading = Array.from(document.querySelectorAll('h2,h3,h4')).find(el => targets.includes(el.textContent.replace(/[\\u200B-\\u200D\\uFEFF]/g,'').trim()));
                const position = heading ? window.scrollY + heading.getBoundingClientRect().top - 24 : 0;
                window.scrollTo({top: Math.max(0,position), behavior:'instant'});
            })();
            """, completionHandler: nil)
        }
    }
}
