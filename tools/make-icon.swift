// make-icon.swift: draws Squelch's icon (a microphone struck through, white on ForIT blue) with Core Graphics,
// so no SF Symbol is used (their licence forbids app icons). Run on a Mac from the repo root:
//   swift tools/make-icon.swift
// Writes assets/icon/Squelch.icns (the Mac app: rounded square inside Apple's 1024 grid, transparent margin)
// and assets/icon/Squelch-ios-1024.png (the iPhone app: full bleed and opaque; App Store Connect rejects alpha).
import AppKit

let blueTop = CGColor(red: 0.16, green: 0.38, blue: 0.95, alpha: 1)
let blueBottom = CGColor(red: 0.05, green: 0.16, blue: 0.52, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// The glyph in a 1024 box: capsule head, U-shaped holder, stem, base, and a slash with a gap cut around it.
// It draws in its own transparency layer, so the gap shows whatever is underneath.
func drawGlyph(_ c: CGContext, in box: CGRect) {
    let s = box.width / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: box.minX + x * s, y: box.minY + y * s, width: w * s, height: h * s)
    }
    c.saveGState()
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setFillColor(white)
    c.setStrokeColor(white)
    c.setLineCap(.round)
    // Head (y grows upward in Core Graphics).
    c.addPath(CGPath(roundedRect: r(402, 430, 220, 360), cornerWidth: 110 * s, cornerHeight: 110 * s, transform: nil))
    c.fillPath()
    // Holder: a U around the lower half of the head.
    c.setLineWidth(52 * s)
    c.addArc(center: CGPoint(x: box.minX + 512 * s, y: box.minY + 560 * s), radius: 182 * s,
             startAngle: .pi, endAngle: 0, clockwise: false)
    c.strokePath()
    // Stem and base.
    c.fill(r(486, 290, 52, 92))
    c.addPath(CGPath(roundedRect: r(392, 262, 240, 52), cornerWidth: 26 * s, cornerHeight: 26 * s, transform: nil))
    c.fillPath()
    // Slash: first clear a wider stroke to cut the gap, then the white bar.
    let a = CGPoint(x: box.minX + 300 * s, y: box.minY + 820 * s)
    let b = CGPoint(x: box.minX + 724 * s, y: box.minY + 236 * s)
    c.setBlendMode(.clear)
    c.setLineWidth(120 * s)
    c.move(to: a); c.addLine(to: b); c.strokePath()
    c.setBlendMode(.normal)
    c.setStrokeColor(white)
    c.setLineWidth(56 * s)
    c.move(to: a); c.addLine(to: b); c.strokePath()
    c.endTransparencyLayer()
    c.restoreGState()
}

func gradient(_ c: CGContext, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [blueTop, blueBottom] as CFArray,
                       locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
                         options: [])
}

func render(_ side: Int, opaque: Bool, draw: (CGContext, CGRect) -> Void) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: info)!
    c.interpolationQuality = .high
    draw(c, CGRect(x: 0, y: 0, width: side, height: side))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// Mac: Apple's grid puts an 824 body with a ~185 corner radius in the middle of 1024, with a soft shadow.
func macIcon(_ side: Int) -> Data {
    render(side, opaque: false) { c, full in
        let k = full.width / 1024
        let body = CGRect(x: 100 * k, y: 100 * k + 12 * k, width: 824 * k, height: 824 * k)
        let path = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k,
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        c.addPath(path); c.setFillColor(blueBottom); c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(path); c.clip()
        gradient(c, body)
        c.restoreGState()
        drawGlyph(c, in: body)
    }
}

// iPhone: full bleed, no transparency anywhere; iOS rounds the corners itself.
func iosIcon() -> Data {
    render(1024, opaque: true) { c, full in
        gradient(c, full)
        drawGlyph(c, in: full.insetBy(dx: 40, dy: 40))
    }
}

let fm = FileManager.default
let out = URL(fileURLWithPath: "assets/icon")
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Squelch-\(getpid()).iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: out, withIntermediateDirectories: true)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try macIcon(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try macIcon(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try macIcon(1024).write(to: out.appendingPathComponent("Squelch-mac-1024.png"))
try iosIcon().write(to: out.appendingPathComponent("Squelch-ios-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("Squelch.icns").path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: set)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote assets/icon/Squelch.icns, Squelch-mac-1024.png, Squelch-ios-1024.png")
