#!/usr/bin/env swift
// Renders the ZenTerm app icon into a .iconset directory, one PNG per size.
// Source of truth for the icon — regenerate with `icon/make-icon.sh`.
// Palette is Rosé Pine Moon (the app's theme): deep indigo tile, iris accent.
import AppKit

// MARK: - Palette (sRGB)
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let iris = rgb(0xC4A7E7)  // brand accent
let muted = rgb(0x6B6790)  // the app's terminal cursor color
let bgTop = rgb(0x221E33)
let bgBottom = rgb(0x141120)

// MARK: - Squircle (superellipse, n≈5 — the Apple corner feel)
func squircle(center c: CGPoint, radius a: CGFloat) -> CGPath {
    let n: CGFloat = 5, steps = 720
    let path = CGMutablePath()
    for i in 0...steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let ct = cos(t), st = sin(t)
        let x = a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = a * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        let p = CGPoint(x: c.x + x, y: c.y + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Draw at a given pixel size
func drawIcon(size: CGFloat) -> CGImage {
    let px = Int(size)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size / 1024  // all geometry authored in 1024 space
    func L(_ v: CGFloat) -> CGFloat { v * s }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Tile
    let center = CGPoint(x: L(512), y: L(512))
    let tile = squircle(center: center, radius: L(412))
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    // Vertical background gradient
    let bg = CGGradient(
        colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: L(512), y: L(924)), end: CGPoint(x: L(512), y: L(100)), options: [])

    // Soft iris glow, lifted slightly above center
    let glow = CGGradient(
        colorsSpace: space, colors: [rgb(0xC4A7E7, 0.16), rgb(0xC4A7E7, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: L(512), y: L(560)), startRadius: 0,
        endCenter: CGPoint(x: L(512), y: L(560)), endRadius: L(400), options: [])

    // Focal glow behind the cursor bar — soft iris, matched to the muted bar
    let cursorGlow = CGGradient(
        colorsSpace: space, colors: [rgb(0xC4A7E7, 0.13), rgb(0xC4A7E7, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        cursorGlow, startCenter: CGPoint(x: L(645), y: L(512)), startRadius: 0,
        endCenter: CGPoint(x: L(645), y: L(512)), endRadius: L(150), options: [])

    // Prompt chevron  ❯
    ctx.setStrokeColor(iris)
    ctx.setLineWidth(L(54))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: L(372), y: L(662)))
    ctx.addLine(to: CGPoint(x: L(528), y: L(512)))
    ctx.addLine(to: CGPoint(x: L(372), y: L(362)))
    ctx.strokePath()

    // Cursor bar — matched to the chevron's tip-to-tip height
    let block = CGPath(
        roundedRect: CGRect(x: L(618), y: L(342), width: L(54), height: L(340)),
        cornerWidth: L(20), cornerHeight: L(20), transform: nil)
    ctx.addPath(block)
    ctx.setFillColor(muted)
    ctx.fillPath()

    ctx.restoreGState()

    // Inner rim highlight — the subtle sheen that reads as depth
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.06))
    ctx.setLineWidth(L(3))
    ctx.strokePath()

    return ctx.makeImage()!
}

// MARK: - Emit the iconset
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (base points, includes @2x) → filenames
let variants: [(Int, Bool)] = [(16, false), (16, true), (32, false), (32, true),
    (128, false), (128, true), (256, false), (256, true), (512, false), (512, true)]
var cache: [Int: Data] = [:]
for (base, retina) in variants {
    let scale = retina ? 2 : 1
    let px = base * scale
    let data: Data
    if let hit = cache[px] {
        data = hit
    } else {
        let rep = NSBitmapImageRep(cgImage: drawIcon(size: CGFloat(px)))
        rep.size = NSSize(width: px, height: px)
        data = rep.representation(using: .png, properties: [:])!
        cache[px] = data
    }
    let name = "icon_\(base)x\(base)\(retina ? "@2x" : "").png"
    try data.write(to: outDir.appendingPathComponent(name))
}
print("✓ wrote \(variants.count) PNGs to \(outDir.path)")
