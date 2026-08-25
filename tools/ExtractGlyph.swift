import AppKit

// Pulls an agent's mark out of its installed .app icon and writes a monochrome
// alpha mask, so the menu bar draws the real logo tinted like any other status
// item rather than a shrunken colour icon.
//
//   ExtractGlyph <in.icns|png> <out.png> [--invert] [--bold R] [--size N]
//                [--low L] [--high H]
//
// --invert   the mark is dark on a light canvas (default: light on dark)
// --bold R   optically thicken by R source-pixels. Logos drawn as thin outlines
//            dissolve at 14pt; Apple's own symbols are far heavier than their
//            print counterparts for exactly this reason.

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1)
}
func flagValue(_ name: String) -> Double? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return Double(CommandLine.arguments[i + 1])
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("usage: ExtractGlyph <in> <out> [--invert] [--alpha] [--chroma] [--trim] "
       + "[--bold R] [--size N]")
}
/// A brand PNG is a flat colour on transparency: its alpha *is* the mark, and
/// measuring luma would just ask how dark the brand colour happens to be.
/// Exported art often still carries an opaque white plate under part of the
/// canvas, so "opaque" alone is not the same as "mark".
let alphaOnly = args.contains("--alpha")
/// Crop to the mark before scaling, for art that sits in a corner of its canvas.
let trim = args.contains("--trim")
/// Keep the coloured pixels and drop the neutral ones.
///
/// The modern app icon is a saturated glyph on a white rounded tile — VS Code
/// is exactly this. Luma can't separate them (the tile is the brightest thing
/// and the glyph is mid-tone), and alpha can't either (the whole tile is
/// opaque). Saturation can: the tile has none and the glyph is nothing but.
let chroma = args.contains("--chroma")
let invert = args.contains("--invert")
let bold = Int(flagValue("--bold") ?? 0)
let outSize = Int(flagValue("--size") ?? 512)
let lowCut = flagValue("--low") ?? 0.62
let highCut = flagValue("--high") ?? 0.92

guard let source = NSImage(contentsOfFile: args[1]) else { fail("can't read \(args[1])") }
let side = max(source.representations.map(\.pixelsWide).max() ?? 512, 512)

/// The mark's bounding box in the source, as a rect in image coordinates.
func inkBounds(_ image: NSImage) -> NSRect? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.bitmapData else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let rowBytes = rep.bytesPerRow, spp = rep.samplesPerPixel
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        let row = data + y * rowBytes
        for x in 0..<w {
            let p = row + x * spp
            let a = Double(p[3]) / 255
            guard a > 0.02 else { continue }
            let r = Double(p[0]) / 255 / a, g = Double(p[1]) / 255 / a, b = Double(p[2]) / 255 / a
            if chroma {
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 0, (high - low) / high > 0.15 else { continue }
            } else if !alphaOnly {
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                guard invert ? luma > 0.06 : luma < 0.94 else { continue }
            }
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let sx = image.size.width / Double(w), sy = image.size.height / Double(h)
    // Bitmap rows run top-down; NSImage coordinates run bottom-up.
    return NSRect(x: Double(minX) * sx, y: Double(h - 1 - maxY) * sy,
                  width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
}

// Keep the mark square so scaling can't stretch it.
let crop: NSRect? = trim ? inkBounds(source).map { box in
    let s = max(box.width, box.height)
    return NSRect(x: box.midX - s / 2, y: box.midY - s / 2, width: s, height: s)
} : nil
if let crop { print("trimmed to \(Int(crop.width))x\(Int(crop.height)) at \(Int(crop.minX)),\(Int(crop.minY))") }

// Rasterise the icon once at full resolution.
guard let src = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no bitmap") }
src.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: src)
NSGraphicsContext.current?.imageInterpolation = .high
if let crop {
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                from: crop, operation: .sourceOver, fraction: 1)
} else {
    source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
}
NSGraphicsContext.restoreGraphicsState()

guard let base = src.bitmapData else { fail("no pixels") }
let rowBytes = src.bytesPerRow, spp = src.samplesPerPixel

// Coverage = how much each pixel belongs to the mark. A smoothstep rather than
// a hard threshold keeps the edges antialiased. Raw buffer access because
// colorAt/setColor are far too slow at 1024².
var coverage = [Double](repeating: 0, count: side * side)
for y in 0..<side {
    let row = base + y * rowBytes
    for x in 0..<side {
        let p = row + x * spp
        let a = Double(p[3]) / 255
        guard a > 0.01 else { continue }
        // The representation is premultiplied; undo it before measuring luma.
        let r = Double(p[0]) / 255 / a, g = Double(p[1]) / 255 / a, b = Double(p[2]) / 255 / a
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        if chroma {
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high <= 0 ? 0 : (high - low) / high
            let t = min(max((saturation - 0.15) / 0.25, 0), 1)
            coverage[y * side + x] = t * t * (3 - 2 * t) * a
            continue
        }
        if alphaOnly {
            // Flat art on transparency: the alpha channel is the silhouette,
            // whatever colour the parts happen to be.
            coverage[y * side + x] = a
            continue
        }
        let v = invert ? 1 - luma : luma
        let t = min(max((v - lowCut) / (highCut - lowCut), 0), 1)
        coverage[y * side + x] = t * t * (3 - 2 * t) * a
    }
}

// Drop anti-aliasing fringes before dilating: a stray edge pixel would
// otherwise bloom into a visible halo the size of the dilation radius.
for i in 0..<coverage.count where coverage[i] < 0.20 { coverage[i] = 0 }

// Separable max-filter dilation: thickens strokes without distorting the shape.
if bold > 0 {
    var tmp = coverage
    for y in 0..<side {
        for x in 0..<side {
            var m = 0.0
            for dx in max(0, x - bold)...min(side - 1, x + bold) { m = max(m, coverage[y * side + dx]) }
            tmp[y * side + x] = m
        }
    }
    for x in 0..<side {
        for y in 0..<side {
            var m = 0.0
            for dy in max(0, y - bold)...min(side - 1, y + bold) { m = max(m, tmp[dy * side + x]) }
            coverage[y * side + x] = m
        }
    }
}

// Trim to the mark so every glyph fills its box identically.
var minX = side, minY = side, maxX = -1, maxY = -1
for y in 0..<side {
    for x in 0..<side where coverage[y * side + x] > 0.35 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    fail("no mark found in \(args[1]) — try --invert, or adjust --low/--high")
}
let boxW = maxX - minX + 1, boxH = maxY - minY + 1
let boxSide = max(boxW, boxH)
if Double(boxSide) > Double(side) * 0.97 {
    FileHandle.standardError.write(Data(
        "warning: mark fills the whole canvas — the background probably matched too\n".utf8))
}

// Write the trimmed, squared mask, then scale to the requested size.
guard let square = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: boxSide, pixelsHigh: boxSide,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no square") }
guard let sq = square.bitmapData else { fail("no square pixels") }
let sqRow = square.bytesPerRow, sqSpp = square.samplesPerPixel
for i in 0..<(sqRow * boxSide) { sq[i] = 0 }
let offX = (boxSide - boxW) / 2, offY = (boxSide - boxH) / 2
for y in 0..<boxH {
    for x in 0..<boxW {
        let c = coverage[(minY + y) * side + (minX + x)]
        guard c > 0 else { continue }
        let p = sq + (y + offY) * sqRow + (x + offX) * sqSpp
        let a = UInt8(min(255, max(0, c * 255)))
        p[0] = a; p[1] = a; p[2] = a; p[3] = a   // premultiplied white
    }
}
square.size = NSSize(width: boxSide, height: boxSide)

guard let out = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: outSize, pixelsHigh: outSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("no out") }
out.size = NSSize(width: outSize, height: outSize)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
square.draw(in: NSRect(x: 0, y: 0, width: outSize, height: outSize))
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: .png, properties: [:]) else { fail("no png") }
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    fail("can't write \(args[2]): \(error.localizedDescription)")
}
print("wrote \(args[2])  \(outSize)² from a \(boxSide)² mark" + (bold > 0 ? "  (bold \(bold))" : ""))
