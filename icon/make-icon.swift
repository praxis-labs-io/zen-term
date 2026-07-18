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
// A `--dev` first argument produces the daily-driver icon: same deep-indigo tile
// as the release, but the origami mark is tinted Rosé Pine rose instead of iris,
// with a small "Dev" chip in the top-right. Same style as the release, different
// accent, so the two are unmistakable side by side.
let isDev = CommandLine.arguments.dropFirst().contains("--dev")
let iris = rgb(0xC4A7E7)  // release mark accent (Rosé Pine Moon iris)
let rose = rgb(0xEA9A97)  // dev mark accent (Rosé Pine Moon rose)
let markColor = isDev ? rose : iris
let bgTop = rgb(0x221E33)  // deep-indigo tile, both variants
let bgBottom = rgb(0x141120)
let badgeSurface = rgb(0x393552)  // Rosé Pine Moon overlay: the "Dev" chip fill

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

// MARK: - SVG path → polylines (Lucide's 24-unit grid, y-down)
// Lets a mark be authored straight from its SVG `d` string. Arcs (Lucide's rounded
// corners) are converted via the SVG endpoint parameterisation and flattened to short
// segments; round joins keep them smooth at icon resolution.
func vecAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
    let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
    let c = max(-1, min(1, (ux * vx + uy * vy) / len))
    return ((ux * vy - uy * vx) < 0 ? -1 : 1) * acos(c)
}

func appendArc(
    from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, xRotDeg: CGFloat,
    largeArc: Bool, sweep: Bool, into pts: inout [CGPoint]
) {
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { pts.append(p1); return }
    let phi = xRotDeg * .pi / 180, cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    if num < 0 { num = 0 }
    var co = (num / den).squareRoot()
    if largeArc == sweep { co = -co }
    let cxp = co * (rx * y1p / ry), cyp = co * (-ry * x1p / rx)
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    let theta1 = vecAngle(1, 0, ux, uy)
    var dTheta = vecAngle(ux, uy, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
    if sweep && dTheta < 0 { dTheta += 2 * .pi }
    let steps = max(2, Int(ceil(abs(dTheta) / (.pi / 16))))
    for i in 1...steps {
        let t = theta1 + dTheta * CGFloat(i) / CGFloat(steps)
        pts.append(
            CGPoint(
                x: cx + rx * cos(t) * cosP - ry * sin(t) * sinP,
                y: cy + rx * cos(t) * sinP + ry * sin(t) * cosP))
    }
}

func parsePath(_ d: String) -> [[CGPoint]] {
    let pattern = "[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?"
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = d as NSString
    let toks = re.matches(in: d, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
    var i = 0
    func num() -> CGFloat {
        var s = toks[i]; i += 1
        if s.hasPrefix(".") { s = "0" + s } else if s.hasPrefix("-.") { s = "-0" + s.dropFirst() }
        return CGFloat(Double(s)!)
    }
    func flag() -> Bool { let v = toks[i] != "0"; i += 1; return v }
    var subpaths: [[CGPoint]] = [], cur: [CGPoint] = []
    var pt = CGPoint.zero, start = CGPoint.zero
    var cmd: Character = " "
    func flush() { if cur.count > 1 { subpaths.append(cur) }; cur = [] }
    while i < toks.count {
        let t = toks[i]
        if t.count == 1, let c = t.first, "MmLlHhVvCcSsQqTtAaZz".contains(c) { cmd = c; i += 1 }
        switch cmd {
        case "M": flush(); pt = CGPoint(x: num(), y: num()); start = pt; cur = [pt]; cmd = "L"
        case "m":
            flush(); pt = CGPoint(x: pt.x + num(), y: pt.y + num()); start = pt; cur = [pt]; cmd = "l"
        case "L": pt = CGPoint(x: num(), y: num()); cur.append(pt)
        case "l": pt = CGPoint(x: pt.x + num(), y: pt.y + num()); cur.append(pt)
        case "H": pt = CGPoint(x: num(), y: pt.y); cur.append(pt)
        case "h": pt = CGPoint(x: pt.x + num(), y: pt.y); cur.append(pt)
        case "V": pt = CGPoint(x: pt.x, y: num()); cur.append(pt)
        case "v": pt = CGPoint(x: pt.x, y: pt.y + num()); cur.append(pt)
        case "A", "a":
            let rel = cmd == "a"
            let rx = num(), ry = num(), rot = num(), la = flag(), sw = flag()
            let ex = num(), ey = num()
            let p1 = rel ? CGPoint(x: pt.x + ex, y: pt.y + ey) : CGPoint(x: ex, y: ey)
            appendArc(from: pt, to: p1, rx: rx, ry: ry, xRotDeg: rot, largeArc: la, sweep: sw, into: &cur)
            pt = p1
        case "Z", "z": pt = start; cur.append(start)
        default: i += 1
        }
    }
    flush()
    return subpaths
}

// The `origami` mark as its three Lucide `d` strings, parsed once with its bounding box.
let origamiPaths = [
    "M12 12V4a1 1 0 0 1 1-1h6.297a1 1 0 0 1 .651 1.759l-4.696 4.025",
    "m12 21-7.414-7.414A2 2 0 0 1 4 12.172V6.415a1.002 1.002 0 0 1 1.707-.707L20 20.009",
    "m12.214 3.381 8.414 14.966a1 1 0 0 1-.167 1.199l-1.168 1.163a1 1 0 0 1-.706.291H6.351"
        + "a1 1 0 0 1-.625-.219L3.25 18.8a1 1 0 0 1 .631-1.781l4.165.027",
]
let origamiSubpaths: [[CGPoint]] = origamiPaths.flatMap(parsePath)
let origamiXs = origamiSubpaths.flatMap { $0.map(\.x) }
let origamiYs = origamiSubpaths.flatMap { $0.map(\.y) }
let origamiCenter = CGPoint(
    x: (origamiXs.min()! + origamiXs.max()!) / 2, y: (origamiYs.min()! + origamiYs.max()!) / 2)
let origamiExtent = max(origamiXs.max()! - origamiXs.min()!, origamiYs.max()! - origamiYs.min()!)

// MARK: - Draw at a given pixel size
/// `square` fills the frame edge to edge with an opaque tile instead of the squircle.
/// The app icon needs the squircle and its transparent margin (macOS aligns icons on a
/// shared grid); an avatar host that rounds and borders the image itself does not, and
/// transparent corners inside its rounding read as a gap. The mark keeps the same share
/// of the tile in both, so they look like the same icon.
func drawIcon(size: CGFloat, square: Bool = false) -> CGImage {
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
    let tile = square
        ? CGPath(rect: CGRect(x: 0, y: 0, width: L(1024), height: L(1024)), transform: nil)
        : squircle(center: center, radius: L(412))
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    // Vertical background gradient, run to the tile's own edges
    let bg = CGGradient(
        colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: L(512), y: L(square ? 1024 : 924)),
        end: CGPoint(x: L(512), y: L(square ? 0 : 100)), options: [])

    // Soft iris glow behind the mark, centered
    let glow = CGGradient(
        colorsSpace: space, colors: [rgb(0xC4A7E7, 0.16), rgb(0xC4A7E7, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: L(512), y: L(512)), startRadius: 0,
        endCenter: CGPoint(x: L(512), y: L(512)), endRadius: L(400), options: [])

    // Origami mark (Lucide `origami`): authored straight from its SVG paths, centred and
    // scaled so its larger dimension fits `430` in icon space (Lucide's y-down grid is
    // flipped into the icon's y-up space). Stroke is lightened to 1.5/24 (below Lucide's
    // 2/24 default) so the crane's fold lines don't crowd at small sizes.
    // The square tile is wider than the squircle (1024 vs 824), so the mark scales with it
    // to hold the same share of the tile.
    let k = L(square ? 430 * 1024 / 824 : 430) / origamiExtent
    func P(_ p: CGPoint) -> CGPoint {
        CGPoint(x: L(512) + (p.x - origamiCenter.x) * k, y: L(512) - (p.y - origamiCenter.y) * k)
    }
    ctx.setStrokeColor(markColor)
    ctx.setLineWidth(1.5 * k)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for sp in origamiSubpaths {
        let path = CGMutablePath()
        path.move(to: P(sp[0]))
        for pt in sp.dropFirst() { path.addLine(to: P(pt)) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    ctx.restoreGState()

    // Inner rim highlight — the subtle sheen that reads as depth. Skipped on the square
    // tile: it traces the tile edge, where the host's own rounding would clip it anyway.
    if !square {
        ctx.addPath(tile)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.06))
        ctx.setLineWidth(L(3))
        ctx.strokePath()
    }

    // Dev badge: a small rounded "Dev" chip in the top-right, filled with the Rosé
    // Pine surface tone and labelled in the rose accent. The rose-tinted mark already
    // sets the dev icon apart at small sizes, so the chip is only drawn where its
    // label is legible (>= 128px). CG here is y-up, so the top-right is high x, high y.
    if isDev && size >= 128 {
        let s = size
        let m = s * 0.085  // inset from the tile's top-right corner
        let h = s * 0.155  // chip height
        let font = NSFont.systemFont(ofSize: h * 0.6, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: rose)!,
        ]
        let label = NSAttributedString(string: "Dev", attributes: attrs)
        let tb = label.size()
        let w = tb.width + h * 0.9  // horizontal padding either side of the label
        let chip = CGRect(x: s - m - w, y: s - m - h, width: w, height: h)
        let radius = h * 0.32
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(badgeSurface)
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        label.draw(at: NSPoint(x: chip.midX - tb.width / 2, y: chip.midY - tb.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, px: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: px, height: px)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Emit
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(
        Data("usage: make-icon.swift <output.iconset> | --avatar <output.png>\n".utf8))
    exit(1)
}

// Avatar: one opaque 1024 PNG for hosts that round and border the image themselves
// (GitHub org/user, Linear, Slack). Not part of the app bundle.
if CommandLine.arguments[1] == "--avatar" {
    guard CommandLine.arguments.count > 2 else {
        FileHandle.standardError.write(Data("usage: make-icon.swift --avatar <output.png>\n".utf8))
        exit(1)
    }
    let out = URL(fileURLWithPath: CommandLine.arguments[2])
    try writePNG(drawIcon(size: 1024, square: true), px: 1024, to: out)
    print("✓ wrote \(out.path)")
    exit(0)
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
