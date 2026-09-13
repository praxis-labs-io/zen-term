#!/usr/bin/env swift
// Renders the DMG window background; Finder draws the two icons on top at the positions bin/make-dmg sets.
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let iris = rgb(0xC4A7E7)
let bgTop = rgb(0x221E33)
let bgBottom = rgb(0x141120)
let textColor = rgb(0xE0DEF4)
let mutedColor = rgb(0x908CAA)

let BASE_W: CGFloat = 660
let BASE_H: CGFloat = 400
// Layout is top-down, Finder's convention, so centers match the coordinates bin/make-dmg hands Finder.
let ICON_ROW_Y: CGFloat = 200
let APP_X: CGFloat = 170
let APPS_X: CGFloat = 490

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

// Keeps clear of the bottom ~28px, which Finder's title-bar-inclusive window bounds clip.
func render(scale: CGFloat) -> CGImage {
    let pxW = Int(BASE_W * scale), pxH = Int(BASE_H * scale)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: scale, y: scale)

    func Y(_ topDown: CGFloat) -> CGFloat { BASE_H - topDown }

    let bg = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: BASE_W / 2, y: BASE_H), end: CGPoint(x: BASE_W / 2, y: 0), options: [])

    let glow = CGGradient(
        colorsSpace: space, colors: [rgb(0xC4A7E7, 0.12), rgb(0xC4A7E7, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: BASE_W / 2, y: Y(ICON_ROW_Y)), startRadius: 0,
        endCenter: CGPoint(x: BASE_W / 2, y: Y(ICON_ROW_Y)), endRadius: 320, options: [])

    func drawOrigami(cx: CGFloat, cyTopDown: CGFloat, height: CGFloat, color: CGColor) {
        let k = height / origamiExtent
        func P(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + (p.x - origamiCenter.x) * k, y: Y(cyTopDown) - (p.y - origamiCenter.y) * k)
        }
        ctx.setStrokeColor(color)
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
    }

    func drawText(_ string: String, cx: CGFloat, cyTopDown: CGFloat, font: NSFont, color: CGColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color)!]
        let s = NSAttributedString(string: string, attributes: attrs)
        let tb = s.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: NSPoint(x: cx - tb.width / 2, y: Y(cyTopDown) - tb.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    let markH: CGFloat = 30
    let wordFont = NSFont.systemFont(ofSize: 30, weight: .semibold)
    let word = NSAttributedString(string: "ZenTerm", attributes: [.font: wordFont])
    let wordW = word.size().width
    let gap: CGFloat = 16
    let wordmarkY: CGFloat = 66
    let total = markH + gap + wordW
    let startX = (BASE_W - total) / 2
    drawOrigami(cx: startX + markH / 2, cyTopDown: wordmarkY, height: markH, color: iris)
    drawText("ZenTerm", cx: startX + markH + gap + wordW / 2, cyTopDown: wordmarkY, font: wordFont, color: textColor)

    let arrowY = Y(ICON_ROW_Y)
    let arrowMidX = (APP_X + APPS_X) / 2
    let shaftHalf: CGFloat = 34
    let head: CGFloat = 11
    let tip = CGPoint(x: arrowMidX + shaftHalf, y: arrowY)
    ctx.setStrokeColor(rgb(0xC4A7E7, 0.55))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: arrowMidX - shaftHalf, y: arrowY))
    arrow.addLine(to: tip)
    arrow.move(to: CGPoint(x: tip.x - head, y: tip.y + head))
    arrow.addLine(to: tip)
    arrow.addLine(to: CGPoint(x: tip.x - head, y: tip.y - head))
    ctx.addPath(arrow)
    ctx.strokePath()

    drawText(
        "Drag ZenTerm to your Applications folder to install.", cx: BASE_W / 2, cyTopDown: 316,
        font: NSFont.systemFont(ofSize: 15, weight: .regular), color: mutedColor)

    return ctx.makeImage()!
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png> [scale]\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scaleArg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1"
guard let scaleValue = Double(scaleArg), scaleValue > 0 else {
    FileHandle.standardError.write(Data("✗ scale must be a positive number (1 or 2)\n".utf8))
    exit(1)
}
let scale = CGFloat(scaleValue)
let image = render(scale: scale)
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: BASE_W, height: BASE_H)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("✓ wrote \(out.path) (\(Int(BASE_W * scale))×\(Int(BASE_H * scale)))")
