import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
let types = ["icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]
func bigEndian(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let bg = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(red: 0, green: 93 / 255, blue: 170 / 255, alpha: 1), ending: NSColor(red: 11 / 255, green: 35 / 255, blue: 67 / 255, alpha: 1))!.draw(in: bg, angle: -80)
    for (y, alpha) in [(290.0, 0.35), (365.0, 0.65), (440.0, 1.0)] {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 257, y: y + 125)); path.line(to: NSPoint(x: 512, y: y + 246)); path.line(to: NSPoint(x: 767, y: y + 125)); path.line(to: NSPoint(x: 512, y: y)); path.close()
        NSColor(white: 1, alpha: alpha).setFill(); path.fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512, y: 700)); arrow.line(to: NSPoint(x: 512, y: 529))
    arrow.move(to: NSPoint(x: 452, y: 589)); arrow.line(to: NSPoint(x: 512, y: 529)); arrow.line(to: NSPoint(x: 572, y: 589))
    arrow.lineWidth = 29; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(red: 0, green: 93 / 255, blue: 170 / 255, alpha: 1).setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: folder.appendingPathComponent(name + ".png"))
    let index = sizes.firstIndex(where: { $0.1 == name })!
    chunks.append(Data(types[index].utf8)); chunks.append(bigEndian(png.count + 8)); chunks.append(png)
}
if CommandLine.arguments.count > 2 {
    var icns = Data("icns".utf8); icns.append(bigEndian(chunks.count + 8)); icns.append(chunks)
    try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
