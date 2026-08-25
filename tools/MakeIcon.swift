// Builds the app icon and the UI mark from Resources/logo/antarium.png.
//
// The artwork is orange ink on transparency with uneven margins, so it is
// trimmed to its ink, squared about that ink's centre and re-inset — otherwise
// the A sits low and small in a 16pt menu, which is where it is read most.
//
//   swift tools/MakeIcon.swift Resources/logo/antarium.png Resources/logo
//
// Then: iconutil -c icns Resources/logo/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: MakeIcon <in.png> <outDir> [--inset 0.90]\n".utf8))
    exit(2)
}
let inset: CGFloat = {
    guard let i = args.firstIndex(of: "--inset"), i + 1 < args.count,
          let v = Double(args[i + 1]) else { return 0.90 }
    return CGFloat(v)
}()
/// Background for the app icon's tile. macOS draws a bare glyph on a plate of
/// its own choosing — a light one, which fought the orange and looked wrong in
/// a dark alert — so the tile is ours, and the same everywhere the icon appears.
/// The in-app mark stays transparent: it is tinted and sits on our own surfaces.
let tile: NSColor? = {
    guard let i = args.firstIndex(of: "--tile"), i + 1 < args.count else { return nil }
    var hex = args[i + 1]
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard let v = UInt32(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}()
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Redraw into a known RGBA8 layout: the source's own representation is not
/// guaranteed to be one, and the alpha scan below indexes raw bytes.
func rgba(_ image: NSImage, _ side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8)); exit(1)
}
let side = 1024
let master = rgba(source, side)
guard let bytes = master.bitmapData else { exit(1) }

// Ink bounds: any pixel carrying alpha at all. The artwork's edges are the
// ants' legs, which are faint, so the threshold stays low deliberately.
var minX = side, minY = side, maxX = -1, maxY = -1
for y in 0..<side {
    for x in 0..<side where bytes[(y * side + x) * 4 + 3] > 8 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
guard maxX >= minX else { FileHandle.standardError.write(Data("image is empty\n".utf8)); exit(1) }
let ink = NSRect(x: CGFloat(minX), y: CGFloat(side - 1 - maxY),
                 width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
// Square about the ink's own centre, so trimming cannot shift the mark.
let reach = max(ink.width, ink.height)
let square = NSRect(x: ink.midX - reach / 2, y: ink.midY - reach / 2, width: reach, height: reach)
print("ink \(Int(ink.width))x\(Int(ink.height)) at \(Int(ink.minX)),\(Int(ink.minY)) -> square \(Int(reach))")

let masterImage = NSImage(size: NSSize(width: side, height: side))
masterImage.addRepresentation(master)

func write(_ pixels: Int, to url: URL, tiled: Bool) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    if tiled, let tile {
        // Apple's own proportions: the tile inset inside the canvas, with a
        // corner radius near a quarter of its width.
        let plate = CGFloat(pixels) * 0.90
        let origin = (CGFloat(pixels) - plate) / 2
        let rect = NSRect(x: origin, y: origin, width: plate, height: plate)
        tile.setFill()
        NSBezierPath(roundedRect: rect, xRadius: plate * 0.235,
                     yRadius: plate * 0.235).fill()
    }
    let box = CGFloat(pixels) * inset
    let origin = (CGFloat(pixels) - box) / 2
    // sourceOver, not copy: copy replaces the tile underneath with the
    // artwork's own transparent corners, leaving a punched-out square.
    masterImage.draw(in: NSRect(x: origin, y: origin, width: box, height: box),
                     from: square, operation: (tiled && tile != nil) ? .sourceOver : .copy,
                     fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

// The mark the dashboard header and the settings title draw. Never tiled: it
// sits on our own surfaces, which already have a background of their own.
write(512, to: outDir.appendingPathComponent("antarium-mark.png"), tiled: false)

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"), tiled: true)
    write(base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"), tiled: true)
}
print("wrote \(iconset.path) and antarium-mark.png")
