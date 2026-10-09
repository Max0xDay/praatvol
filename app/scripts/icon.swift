import AppKit
import Foundation

func generateIcon(destination: String, development: Bool) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "praatvol-icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    (development ? NSColor.systemIndigo : NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.43, alpha: 1)).setFill()
    NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
    NSColor.white.setStroke()
    let wave = NSBezierPath()
    wave.lineWidth = 56
    wave.lineCapStyle = .round
    for index in 0...200 {
        let fraction = Double(index) / 200
        let point = NSPoint(x: 170 + 684 * fraction, y: 512 + 180 * sin(2 * .pi * fraction))
        if index == 0 { wave.move(to: point) } else { wave.line(to: point) }
    }
    wave.stroke()
    if development {
        ("D" as NSString).draw(at: NSPoint(x: 745, y: 115), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 160), .foregroundColor: NSColor.white])
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "praatvol-icon", code: 2)
    }
    try png.write(to: URL(fileURLWithPath: destination))
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "praatvol-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Usage: icon.swift output.png dev|release"])
    }
    try generateIcon(destination: CommandLine.arguments[1], development: CommandLine.arguments[2] == "dev")
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
