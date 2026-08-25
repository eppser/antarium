import AppKit
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path) else { print("load failed"); exit(1) }
print("size=\(img.size) reps=\(img.representations.count) " +
      img.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ","))
let side = 256
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
var maxA = 0.0, maxL = 0.0, opaque = 0
for y in stride(from: 0, to: side, by: 3) { for x in stride(from: 0, to: side, by: 3) {
  guard let p = rep.colorAt(x: x, y: y) else { continue }
  let a = p.alphaComponent
  let l = 0.299*p.redComponent + 0.587*p.greenComponent + 0.114*p.blueComponent
  maxA = max(maxA, a); maxL = max(maxL, l); if a > 0.5 { opaque += 1 }
}}
print(String(format: "maxAlpha=%.2f maxLuma=%.2f opaqueSamples=%d", maxA, maxL, opaque))
