// Draws Antarium's Zed mark.
//
// Zed is the one agent whose mark is not extracted from its app. Its icon is a
// Z built from a squared spiral, and at a 12pt row that detail collapses: every
// luma threshold and every --bold value tried produced the same grey smear with
// a striped band across the bottom. Glyphs' own rule is that a mark keeps only
// the silhouette that stays recognisable at this size, so Zed's keeps the
// diagonal Z the eye actually reads and drops the spiral around it.
//
//   swift tools/ZedMark.swift Resources/marks/zed.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/marks/zed.png"
let side = 512.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: Int(side) * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.shouldAntialias = true

// White ink on transparency: Glyphs tints the mask with sourceIn, so only the
// alpha matters — but the colour must be white or the tint darkens.
NSColor.white.setFill()
NSColor.white.setStroke()

let x0 = side * 0.16, x1 = side * 0.84
let top = side * 0.82, bottom = side * 0.18
let bar = side * 0.155           // bar thickness, matched to the source's weight

NSRect(x: x0, y: top - bar, width: x1 - x0, height: bar).fill()
NSRect(x: x0, y: bottom, width: x1 - x0, height: bar).fill()

let diagonal = NSBezierPath()
diagonal.move(to: NSPoint(x: x1 - bar / 2, y: top - bar / 2))
diagonal.line(to: NSPoint(x: x0 + bar / 2, y: bottom + bar / 2))
diagonal.lineWidth = bar
diagonal.lineCapStyle = .butt
diagonal.stroke()

NSGraphicsContext.restoreGraphicsState()
try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
