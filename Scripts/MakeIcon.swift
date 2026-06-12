#!/usr/bin/swift
// Generates the Tuck app icon as an .iconset directory.
// Usage: swift Scripts/MakeIcon.swift <output.iconset>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(px: Int, name: String) {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("rep") }
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: content occupies ~82% of the canvas, big corner radius.
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.46, green: 0.40, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.66, alpha: 1.0),
    ])!
    gradient.draw(in: squircle, angle: -65)

    // Subtle top sheen.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    squircle.addClip()
    sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // White rounded vertical bar near the right edge — the "divider".
    let barW = rect.width * 0.06
    let barH = rect.height * 0.44
    let bar = NSBezierPath(
        roundedRect: NSRect(x: rect.minX + rect.width * 0.70, y: rect.midY - barH / 2, width: barW, height: barH),
        xRadius: barW / 2, yRadius: barW / 2
    )
    NSColor.white.setFill()
    bar.fill()

    // Chevrons sliding toward the divider, fading out to the left.
    func chevron(centerX: CGFloat, alpha: CGFloat) {
        let w = rect.width * 0.105
        let h = rect.height * 0.30
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centerX - w / 2, y: rect.midY + h / 2))
        path.line(to: NSPoint(x: centerX + w / 2, y: rect.midY))
        path.line(to: NSPoint(x: centerX - w / 2, y: rect.midY - h / 2))
        path.lineWidth = rect.width * 0.06
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
    chevron(centerX: rect.minX + rect.width * 0.52, alpha: 1.00)
    chevron(centerX: rect.minX + rect.width * 0.36, alpha: 0.55)
    chevron(centerX: rect.minX + rect.width * 0.22, alpha: 0.28)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    render(px: px, name: name)
}
print("Icon set written to \(outDir)")
