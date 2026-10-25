// Builds chromeGIST's extension icons from GIST's macOS icon artwork.
// Run via tools/gen-icons.sh.
//
// Usage: swift gen-icons.swift <source.png> <out-master.png>
//
// The source is an opaque 1024×1024 PNG: GIST's rounded dark body with a
// blue glow, on white. Chrome's icon guideline is a 128 px canvas with the
// artwork in the central 96 px and transparent padding, so the output is
// transparent outside the body, with the glow kept as a soft translucent
// shadow, and the body scaled to 96/128 of the canvas.
//
// 1. Flood-fill from the edges across light pixels (max channel >
//    passThreshold): everything reached is outside the body. The cream
//    pages and white lens rim inside the body are never reached.
// 2. Outside pixels: "colour to alpha" against white. Each becomes the most
//    transparent colour that composites back to the original over white, so
//    the blue glow turns translucent rather than being cut off.
// 3. The body's outermost `edgeBand` px (blended with the white, but too
//    dark for the fill to reach) are un-blended against the body colour, so
//    dark browser toolbars show no light outline.
// Same approach contextGIST first used for its macOS icon.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024
let bodyFraction = 96.0 / 128.0
let passThreshold = 48   // 36 leaks through the paper texture (fill-ratio check catches it)
let edgeBand = 2
let noiseAlpha = 4       // source "white" isn't pure white

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: gen-icons.swift <source.png> <out-master.png>\n".data(using: .utf8)!)
    exit(2)
}
func fail(_ m: String) -> Never { FileHandle.standardError.write("error: \(m)\n".data(using: .utf8)!); exit(1) }

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(args[1])") }
let w = image.width, h = image.height
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func context(_ data: UnsafeMutableRawPointer?, _ cw: Int, _ ch: Int) -> CGContext {
    CGContext(data: data, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
var px = [UInt8](repeating: 0, count: w * h * 4)
px.withUnsafeMutableBytes { context($0.baseAddress, w, h).draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }

// ── 1. Find the outside ─────────────────────────────────────────────────────
var dist = [Int](repeating: Int.max, count: w * h) // 0 = outside; 1…n = px inside the edge
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let i = stack.popLast() {
    if dist[i] == 0 || max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) <= passThreshold { continue }
    dist[i] = 0
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
}
var minX = w, minY = h, maxX = -1, maxY = -1, bodyCount = 0
for i in 0..<(w * h) where dist[i] != 0 {
    let x = i % w, y = i / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); bodyCount += 1
}
guard maxX >= 0 else { fail("no icon body found") }
let bodyW = Double(maxX - minX + 1), bodyH = Double(maxY - minY + 1)
let fillRatio = Double(bodyCount) / (bodyW * bodyH)
print(String(format: "body %.0fx%.0f, fills %.0f%% of its box", bodyW, bodyH, fillRatio * 100))
guard fillRatio > 0.75 else { fail("fill ratio \(fillRatio) too low: background removal leaked into the artwork") }

// Distances into the body, for the edge band and the body-colour sample.
var frontier = (0..<(w * h)).filter { dist[$0] == 0 }
for d in 1...(edgeBand + 4) {
    var next: [Int] = []
    for i in frontier {
        let x = i % w, y = i / w
        for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
        where n >= 0 && dist[n] == Int.max { dist[n] = d; next.append(n) }
    }
    frontier = next
}
var sum = [0, 0, 0], samples = 0
for i in 0..<(w * h) where dist[i] >= edgeBand + 2 && dist[i] <= edgeBand + 4 {
    for c in 0..<3 { sum[c] += Int(px[i * 4 + c]) }; samples += 1
}
let body = sum.map { $0 / max(samples, 1) }
let bodyMin = body.min()!

// ── 2 & 3. Make the outside transparent; un-blend the edge band ────────────
for i in 0..<(w * h) {
    let d = dist[i]
    if d == 0 {
        let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
        var a = max(255 - r, 255 - g, 255 - b)
        if a < noiseAlpha { a = 0 }
        let lift = 255 - a // premultiplied value = c - 255(1 - a)
        px[i * 4] = UInt8(max(0, r - lift)); px[i * 4 + 1] = UInt8(max(0, g - lift)); px[i * 4 + 2] = UInt8(max(0, b - lift))
        px[i * 4 + 3] = UInt8(a)
    } else if d <= edgeBand {
        // body colour at alpha t over white: t = (255 - lightest) / (255 - bodyMin)
        let lightest = min(Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2]))
        let t = min(1, max(0, Double(255 - lightest) / Double(255 - bodyMin)))
        for c in 0..<3 { px[i * 4 + c] = UInt8((Double(body[c]) * t).rounded()) }
        px[i * 4 + 3] = UInt8((255 * t).rounded())
    }
}
let processed: CGImage = px.withUnsafeMutableBytes { context($0.baseAddress, w, h).makeImage()! }

// ── Layout: body at 96/128 of the canvas, centred ──────────────────────────
let scale = Double(canvas) * bodyFraction / max(bodyW, bodyH)
let cx = Double(minX) + bodyW / 2, cy = Double(h) - (Double(minY) + bodyH / 2)
let out = context(nil, canvas, canvas)
out.interpolationQuality = .high
out.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
out.draw(processed, in: CGRect(x: Double(canvas) / 2 - cx * scale, y: Double(canvas) / 2 - cy * scale,
                               width: Double(w) * scale, height: Double(h) * scale))
let master = out.makeImage()!
let data = master.dataProvider!.data! as Data
var edgeAlpha = 0
for k in 0..<canvas {
    for i in [k, (canvas - 1) * canvas + k, k * canvas, k * canvas + canvas - 1] { edgeAlpha = max(edgeAlpha, Int(data[i * 4 + 3])) }
}
guard edgeAlpha == 0 else { fail("glow clipped at the canvas edge (alpha \(edgeAlpha))") }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("can't write \(args[2])") }
CGImageDestinationAddImage(dest, master, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG encode failed") }
print("✓ master written (body \(Int(Double(canvas) * bodyFraction)) px of \(canvas), nothing clipped)")
