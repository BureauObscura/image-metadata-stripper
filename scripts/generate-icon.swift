import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate-icon <output.icns>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1], isDirectory: false)

let variants: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("icp6", 64),
    ("ic12", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1024)
]

func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconError.renderFailed
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.renderFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)

    let tile = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    NSColor(calibratedRed: 0.105, green: 0.145, blue: 0.175, alpha: 1).setFill()
    tile.fill()

    let photoFrame = NSBezierPath(roundedRect: NSRect(x: 188, y: 236, width: 648, height: 552), xRadius: 76, yRadius: 76)
    photoFrame.lineWidth = 44
    photoFrame.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.96).setStroke()
    photoFrame.stroke()

    let sun = NSBezierPath(ovalIn: NSRect(x: 610, y: 586, width: 92, height: 92))
    NSColor.white.withAlphaComponent(0.96).setFill()
    sun.fill()

    let landscape = NSBezierPath()
    landscape.move(to: NSPoint(x: 228, y: 326))
    landscape.line(to: NSPoint(x: 400, y: 506))
    landscape.line(to: NSPoint(x: 506, y: 408))
    landscape.line(to: NSPoint(x: 610, y: 516))
    landscape.line(to: NSPoint(x: 796, y: 326))
    landscape.lineWidth = 44
    landscape.lineCapStyle = .round
    landscape.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.96).setStroke()
    landscape.stroke()

    let badge = NSBezierPath(ovalIn: NSRect(x: 650, y: 118, width: 244, height: 244))
    NSColor(calibratedRed: 0.20, green: 0.68, blue: 0.45, alpha: 1).setFill()
    badge.fill()
    NSColor(calibratedWhite: 0.08, alpha: 0.22).setStroke()
    badge.lineWidth = 12
    badge.stroke()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: 708, y: 236))
    check.line(to: NSPoint(x: 758, y: 184))
    check.line(to: NSPoint(x: 844, y: 286))
    check.lineWidth = 32
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.renderFailed
    }
    return png
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

var chunks = Data()
for variant in variants {
    let png = try makeIcon(pixels: variant.pixels)
    chunks.append(Data(variant.type.utf8))
    appendBigEndian(UInt32(png.count + 8), to: &chunks)
    chunks.append(png)
}

var icon = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &icon)
icon.append(chunks)
try icon.write(to: outputURL)

private enum IconError: Error {
    case renderFailed
}
