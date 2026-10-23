import AppKit
import SwiftUI

/// Product photos are copied into the app so scrolling does not depend on a
/// network request. An unknown future identifier uses the native device symbol.
@MainActor
private final class DevicePhotoStore {
    static let shared = DevicePhotoStore()
    private let directory: URL?
    private let filenames: [String: String]
    private let images = NSCache<NSString, NSImage>()

    private init() {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("DevicePhotos", isDirectory: true)
        if let packaged, FileManager.default.fileExists(atPath: packaged.appendingPathComponent("manifest.json").path) {
            directory = packaged
        } else if Bundle.main.bundleURL.pathExtension != "app" {
            directory = Bundle.module.resourceURL?.appendingPathComponent("DevicePhotos", isDirectory: true)
        } else {
            // A damaged or incomplete app bundle should still show device symbols.
            directory = nil
        }
        if let url = directory?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: url) {
            filenames = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            filenames = [:]
        }
        images.countLimit = 180
        images.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for modelIdentifier: String) -> NSImage? {
        guard let filename = filenames[modelIdentifier], let directory,
              filename == (filename as NSString).lastPathComponent else { return nil }
        if let cached = images.object(forKey: filename as NSString) { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        images.setObject(image, forKey: filename as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct DevicePhotoView: View {
    let modelIdentifier: String
    var width: CGFloat = 96
    var height: CGFloat = 78

    var body: some View {
        Group {
            if let image = DevicePhotoStore.shared.image(for: modelIdentifier) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(2)
            } else {
                Image(systemName: modelIdentifier.hasPrefix("iPad") ? "ipad" : "iphone")
                    .font(.system(size: min(width, height) * 0.52, weight: .light))
                    .foregroundStyle(Palette.blue)
            }
        }
        .frame(width: width, height: height)
        .background(.white, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}
