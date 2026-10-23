import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.shutdown() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct RestoreDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("RestoreDock", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme(.light)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1190, height: 810)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("Check for Firmware") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button("Open Firmware Folder") { model.revealLibrary() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra("RestoreDock", systemImage: "square.stack.3d.up.fill") {
            RestoreDockMenu().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RestoreDockMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("RestoreDock", systemImage: "square.stack.3d.up.fill").font(.headline)
            Text("\(model.readyItems.count) ready · \(model.pendingItems.count) in queue").foregroundStyle(.secondary)
            if let item = model.downloads.items.first(where: { $0.status == .downloading }) {
                Text(item.name).font(.subheadline)
                ProgressView(value: item.expectedBytes.map { min(1, Double(item.downloadedBytes) / Double(max(1, $0))) } ?? 0)
                Text("\(byteString(item.downloadedBytes)) downloaded").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            Button("Open RestoreDock") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button(model.refreshing ? "Checking…" : "Check for firmware") { Task { await model.refresh() } }.disabled(model.refreshing)
            Button(model.downloads.isPaused ? "Resume downloads" : "Pause downloads") {
                if model.downloads.isPaused { model.downloads.resume() } else { model.downloads.pause() }
            }
            Divider()
            Text("Checks every \(model.preferences.intervalHours) hours while this Mac is awake and the app is running.").font(.caption).foregroundStyle(.secondary)
            Button("Quit RestoreDock") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }.buttonStyle(.borderless).padding(22).frame(width: 310).tint(Palette.blue).preferredColorScheme(.light)
    }
}
