// SPDX-License-Identifier: GPL-3.0-or-later
// Original project artwork. Run: swift scripts/generate-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("work/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int, to output: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.40, blue: 0.38, alpha: 1),
        ending: NSColor(srgbRed: 0.025, green: 0.23, blue: 0.27, alpha: 1))!.draw(in: background, angle: -45)
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 215, y: 348))
    folder.line(to: NSPoint(x: 215, y: 665))
    folder.curve(to: NSPoint(x: 245, y: 695), controlPoint1: NSPoint(x: 215, y: 685), controlPoint2: NSPoint(x: 225, y: 695))
    folder.line(to: NSPoint(x: 434, y: 695))
    folder.line(to: NSPoint(x: 490, y: 637))
    folder.line(to: NSPoint(x: 782, y: 637))
    folder.curve(to: NSPoint(x: 812, y: 607), controlPoint1: NSPoint(x: 802, y: 637), controlPoint2: NSPoint(x: 812, y: 627))
    folder.line(to: NSPoint(x: 812, y: 348));folder.close()
    NSColor(srgbRed: 0.69, green: 0.83, blue: 0.76, alpha: 1).setFill();folder.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 215, y: 290, width: 597, height: 308), xRadius: 38, yRadius: 38)
    NSColor(srgbRed: 0.92, green: 0.96, blue: 0.87, alpha: 1).setFill();front.fill()
    let route = NSBezierPath();route.move(to: NSPoint(x: 321, y: 377));route.line(to: NSPoint(x: 451, y: 505));route.line(to: NSPoint(x: 565, y: 400));route.line(to: NSPoint(x: 710, y: 535))
    route.lineWidth = 25;route.lineCapStyle = .round;route.lineJoinStyle = .round
    NSColor(srgbRed: 0.12, green: 0.43, blue: 0.38, alpha: 1).setStroke();route.stroke()
    NSColor(srgbRed: 0.89, green: 0.65, blue: 0.31, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 678, y: 503, width: 64, height: 64)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}

for size in [16, 32, 128, 256, 512] {
    try render(size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process();process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("packaging/AppIcon.icns").path]
try process.run();process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(512, to: root.appendingPathComponent("assets/icon.png"))
print("Generated original icon: packaging/AppIcon.icns and assets/icon.png")
