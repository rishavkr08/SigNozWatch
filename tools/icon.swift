// App icon generator. No assets, everything is drawn.
//   swift tools/icon.swift sheet  <out.png>          contact sheet of every concept at 220 / 64 / 32 px
//   swift tools/icon.swift icns   <concept> <out.icns>   build the .icns for one concept (A–E)
import AppKit

let S: CGFloat = 1024   // every concept is drawn in a 1024 × 1024 space, origin bottom-left

let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
let orange = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)
let red = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
let white = NSColor.white

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func squircle(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.height * 0.2237) }

func background(_ top: NSColor, _ bottom: NSColor) {
    let p = squircle(NSRect(x: 0, y: 0, width: S, height: S))
    NSGradient(starting: top, ending: bottom)!.draw(in: p, angle: -90)
}

func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat, cap: NSBezierPath.LineCapStyle = .round) {
    path.lineWidth = width
    path.lineCapStyle = cap
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func arc(center: NSPoint, radius: CGFloat, from a: CGFloat, to b: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: radius, startAngle: a, endAngle: b, clockwise: true)
    return p
}

func dot(_ c: NSPoint, _ r: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
}

func line(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    return p
}

// MARK: - Concepts

let concepts: [(String, String, () -> Void)] = [
    ("A", "Gauge", {
        background(hex(0x24365e), hex(0x0d1529))
        let c = NSPoint(x: 512, y: 400)
        stroke(arc(center: c, radius: 300, from: 200, to: 127), green, width: 74, cap: .butt)
        stroke(arc(center: c, radius: 300, from: 123, to: 50), orange, width: 74, cap: .butt)
        stroke(arc(center: c, radius: 300, from: 46, to: -20), red, width: 74, cap: .butt)
        let needle = NSBezierPath()
        needle.move(to: c)
        needle.line(to: NSPoint(x: c.x + 250 * cos(112 * .pi / 180), y: c.y + 250 * sin(112 * .pi / 180)))
        stroke(needle, white, width: 30)
        dot(c, 52, white)
        dot(c, 20, hex(0x0d1529))
    }),
    ("B", "Pulse", {
        background(hex(0x1e7bff), hex(0x0b3f96))
        stroke(NSBezierPath(ovalIn: NSRect(x: 262, y: 340, width: 500, height: 500)), white, width: 62)
        dot(NSPoint(x: 512, y: 590), 96, green)
        stroke(line([(150, 190), (330, 190), (400, 265), (470, 125), (540, 240), (600, 190), (874, 190)]), white, width: 34)
    }),
    ("C", "Bars", {
        background(hex(0xfafafc), hex(0xe4e5ec))
        let bars: [(CGFloat, CGFloat, NSColor)] = [(222, 300, green), (432, 480, orange), (642, 680, red)]
        for (x, h, color) in bars {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 182, width: 160, height: h), xRadius: 44, yRadius: 44).fill()
        }
        hex(0xc9cad3).setFill()
        NSBezierPath(roundedRect: NSRect(x: 182, y: 150, width: 660, height: 18), xRadius: 9, yRadius: 9).fill()
    }),
    ("D", "Heartbeat", {
        background(hex(0x1c1f26), hex(0x0c0d11))
        let grid = NSBezierPath()
        for i in 1..<6 {
            grid.move(to: NSPoint(x: 0, y: CGFloat(i) * S / 6)); grid.line(to: NSPoint(x: S, y: CGFloat(i) * S / 6))
            grid.move(to: NSPoint(x: CGFloat(i) * S / 6, y: 0)); grid.line(to: NSPoint(x: CGFloat(i) * S / 6, y: S))
        }
        squircle(NSRect(x: 0, y: 0, width: S, height: S)).addClip()
        stroke(grid, white.withAlphaComponent(0.07), width: 6, cap: .butt)
        stroke(line([(90, 512), (330, 512), (400, 512), (455, 720), (525, 290), (595, 640), (650, 512), (934, 512)]), hex(0x3dff8a), width: 46)
        dot(NSPoint(x: 525, y: 290), 40, red)
    }),
    ("E", "Rings", {
        background(hex(0x30333b), hex(0x16171b))
        let c = NSPoint(x: 512, y: 512)
        for (r, color, frac) in [(360, red, 0.94), (262, orange, 0.61), (164, green, 0.26)] as [(CGFloat, NSColor, CGFloat)] {
            stroke(NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), white.withAlphaComponent(0.10), width: 82)
            stroke(arc(center: c, radius: r, from: 90, to: 90 - 360 * frac), color, width: 82)
        }
    }),
]

// MARK: - Rendering

func render(_ draw: () -> Void, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform()
    t.scale(by: CGFloat(px) / S)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

func sheet(to path: String) {
    let scale = 2, cell = 260, w = cell * concepts.count + 40, h = 440
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    hex(0xf2f2f5).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: hex(0x1d1d1f)]
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: hex(0x6b6b70)]
    for (i, c) in concepts.enumerated() {
        let x = 20 + i * cell
        for (px, y) in [(220, 180), (64, 70), (32, 70)] {
            let img = NSImage(size: NSSize(width: px, height: px))
            img.addRepresentation(render(c.2, px: px * scale))
            let dx = px == 220 ? 20 : px == 64 ? 20 : 100
            img.draw(in: NSRect(x: x + dx, y: y, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSAttributedString(string: "\(c.0) · \(c.1)", attributes: label).draw(at: NSPoint(x: x + 20, y: 410))
        NSAttributedString(string: "at 64 and 32 px (notification, Dock badge)", attributes: small).draw(at: NSPoint(x: x + 20, y: 40))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! png(rep).write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func icns(concept letter: String, to path: String) {
    guard let c = concepts.first(where: { $0.0 == letter }) else { print("no concept \(letter)"); exit(1) }
    let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! png(render(c.2, px: base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(render(c.2, px: base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", path]
    try! p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote \(path) (concept \(letter))" : "iconutil failed")
    exit(p.terminationStatus)
}

let args = CommandLine.arguments
switch (args.count, args.dropFirst().first) {
case (3, "sheet"): sheet(to: args[2])
case (4, "icns"): icns(concept: args[2].uppercased(), to: args[3])
default: print("usage: icon.swift sheet <out.png> | icns <A-E> <out.icns>"); exit(2)
}
