import AppKit

// The picture behind the icons in Bros.dmg: dithered oranges on black (the
// site's look), a pixel arrow from the app to the Applications folder.
//
//   swift tools/dmg-background.swift build/dmg-background.png
//
// 660 × 400 points, drawn at 2x. Keep these in step with bros-release.sh:
// app icon at (165, 165), Applications at (495, 165), the read-me at (330, 322).

let width = 660, height = 400, scale = 2
let cell = 2                       // one dither dot, in points
let cols = width / cell, rows = height / cell
let pw = width * scale, ph = height * scale

func rgb(_ hex: UInt32) -> (UInt8, UInt8, UInt8) {
    (UInt8((hex >> 16) & 255), UInt8((hex >> 8) & 255), UInt8(hex & 255))
}
// Dark to light.
let ramp: [(UInt8, UInt8, UInt8)] = [rgb(0x0a0402), rgb(0x3d1605), rgb(0x8f3508), rgb(0xd9570f), rgb(0xff7a1a), rgb(0xffa24a)]
let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

var pixels = [UInt8](repeating: 255, count: pw * ph * 4)
func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
    guard x >= 0, y >= 0, x < pw, y < ph else { return }
    let i = (y * pw + x) * 4
    pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
}
func block(_ gx: Int, _ gy: Int, _ size: Int, _ c: (UInt8, UInt8, UInt8)) {
    for y in 0..<size { for x in 0..<size { put(gx + x, gy + y, c) } }
}

// The field: streaks that run across, as on the site, brighter toward the
// bottom, kept calm where the labels sit so black or white text both read.
func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
func field(_ gx: Int, _ gy: Int) -> Double {
    let x = Double(gx) / Double(cols), y = Double(gy) / Double(rows)
    let streak = sin(y * 46 + sin(x * 3.2) * 1.6) * 0.6 + sin(y * 120 + x * 2.0) * 0.4
    // Dark above and below, where white words stand; an even orange between,
    // where Finder's own labels sit (black or white by the Mac's look): both
    // keep their contrast there.
    let header = 1 - smooth(0.16, 0.30, y)
    let footer = 0.0
    let middle = 0.60 + 0.045 * streak + 0.03 * exp(-pow((x - 0.5) * 2.2, 2) - pow((y - 0.55) * 3, 2))
    let top = 0.10 + 0.07 * streak + 0.10 * smooth(0.0, 0.3, y)
    let bottom = 0.12 + 0.07 * streak
    return min(max(middle * (1 - header) * (1 - footer) + top * header + bottom * footer, 0), 1)
}
for gy in 0..<rows {
    for gx in 0..<cols {
        let level = field(gx, gy) * Double(ramp.count - 1)
        let low = Int(level.rounded(.down))
        let frac = level - Double(low)
        let threshold = (bayer[gy % 4][gx % 4] + 0.5) / 16
        let pick = min(ramp.count - 1, low + (frac > threshold ? 1 : 0))
        // Behind Finder's labels, a strip of two near-equal oranges: dark text
        // and white text both stay readable on it.
        let py = Double(gy * cell)
        let strip = smooth(205, 214, py)
        if strip > threshold + 0.001 {
            block(gx * cell * scale, gy * cell * scale, cell * scale, (gx + gy) % 2 == 0 ? rgb(0xbd4a0b) : rgb(0xc4500d))
        } else {
            block(gx * cell * scale, gy * cell * scale, cell * scale, ramp[pick])
        }
    }
}

// The arrow, in blocks of 8 points.
let arrow = [
    "......X.....",
    "......XX....",
    "......XXX...",
    "XXXXXXXXXX..",
    "XXXXXXXXXXX.",
    "XXXXXXXXXX..",
    "......XXX...",
    "......XX....",
    "......X.....",
]
let unit = 8 * scale
let ax = (width * scale - 12 * unit) / 2, ay = 165 * scale - (9 * unit) / 2
for (r, line) in arrow.enumerated() {
    for (c, ch) in line.enumerated() where ch == "X" {
        block(ax + c * unit + unit / 2, ay + r * unit + unit / 2, unit, rgb(0x2a0d03))   // shadow
    }
}
for (r, line) in arrow.enumerated() {
    for (c, ch) in line.enumerated() where ch == "X" {
        block(ax + c * unit, ay + r * unit, unit, rgb(0xfff1e3))
    }
}

// Contrast, as WCAG reads it, of the words and of Finder's labels.
func luminance(_ c: (UInt8, UInt8, UInt8)) -> Double {
    func lin(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
}
func worst(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, ink: Double) -> Double {
    var low = 99.0
    for y in stride(from: y0 * scale, to: y1 * scale, by: 2) {
        for x in stride(from: x0 * scale, to: x1 * scale, by: 2) {
            let i = (y * pw + x) * 4
            let l = luminance((pixels[i], pixels[i + 1], pixels[i + 2]))
            let ratio = (max(l, ink) + 0.05) / (min(l, ink) + 0.05)
            low = min(low, ratio)
        }
    }
    return low
}
let white = 1.0, black = 0.0
let fileLabel = (worst(290, 370, 346, 372, ink: white), worst(290, 370, 346, 372, ink: black))
let f = { (v: Double) in String(format: "%.1f", v) }
FileHandle.standardError.write(Data(("contrast  title: \(f(worst(150, 510, 40, 85, ink: white)))  footer: \(f(worst(120, 540, 262, 292, ink: white)))  labels white: \(f(min(worst(110, 220, 216, 248, ink: white), worst(440, 550, 216, 248, ink: white))))  file label white/black: \(f(fileLabel.0))/\(f(fileLabel.1))  labels black: \(f(min(worst(110, 220, 216, 248, ink: black), worst(440, 550, 216, 248, ink: black))))\n").utf8))

// The line at the top.
let image = NSImage(size: NSSize(width: pw, height: ph))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pw * 4, bitsPerPixel: 32)!
pixels.withUnsafeBufferPointer { rep.bitmapData!.update(from: $0.baseAddress!, count: $0.count) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, color: NSColor, mono: Bool = false) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size * CGFloat(scale), weight: weight)
                    : NSFont.systemFont(ofSize: size * CGFloat(scale), weight: weight)
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: -0.6]
    let str = NSAttributedString(string: s, attributes: a)
    let w = str.size().width
    str.draw(at: NSPoint(x: (CGFloat(pw) - w) / 2, y: CGFloat(ph) - y * CGFloat(scale)))
}
text("Drag brOS to Applications", size: 26, weight: .semibold, y: 70, color: NSColor(red: 1, green: 0.95, blue: 0.9, alpha: 1))
let ink = NSColor.white
text("macOS says it can't verify Bros? Open the file below and copy the command.", size: 11.5, weight: .semibold, y: 282, color: .white, mono: true)
NSGraphicsContext.restoreGraphicsState()
rep.size = NSSize(width: width, height: height)           // 144 dpi: Finder draws it at 660 × 400
image.addRepresentation(rep)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
