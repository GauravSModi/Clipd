#!/usr/bin/env swift
// Draws Clipd's application icon from plain AppKit shapes and writes it out,
// either as a comparison sheet of every style or as the Xcode asset catalog.
//
// Usage: swift scripts/make_app_icon.swift preview
//            -> build/icon-previews/compare.png (every style, several sizes)
//        swift scripts/make_app_icon.swift install <blue|graphite|orange>
//            -> shell/Clipd/Assets.xcassets/AppIcon.appiconset (the 10 mac slots)
//
// The clipboard glyph is hand-drawn on purpose: Apple's SF Symbols licence
// forbids using symbols in app icons, so the menu bar's doc.on.clipboard can't
// be reused here.
import AppKit

// MARK: - Styles

struct Palette {
    let name: String
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let board: NSColor     // front clipboard sheet
    let backCard: NSColor  // the sheet peeking out behind it — the "history"
    let clip: NSColor
    let lines: NSColor     // the "text" on the front sheet
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let palettes: [Palette] = [
    Palette(name: "blue",
            backgroundTop: srgb(0.33, 0.66, 1.00), backgroundBottom: srgb(0.10, 0.34, 0.86),
            board: srgb(1, 1, 1), backCard: srgb(1, 1, 1, 0.45),
            clip: srgb(0.09, 0.20, 0.52), lines: srgb(0.74, 0.82, 0.95)),
    Palette(name: "graphite",
            backgroundTop: srgb(0.25, 0.27, 0.31), backgroundBottom: srgb(0.08, 0.09, 0.11),
            board: srgb(0.94, 0.95, 0.96), backCard: srgb(1, 1, 1, 0.28),
            clip: srgb(0.18, 0.83, 0.75), lines: srgb(0.70, 0.73, 0.77)),
    Palette(name: "orange",
            backgroundTop: srgb(1.00, 0.72, 0.30), backgroundBottom: srgb(0.98, 0.36, 0.36),
            board: srgb(1, 1, 1), backCard: srgb(1, 1, 1, 0.45),
            clip: srgb(0.58, 0.18, 0.12), lines: srgb(0.99, 0.80, 0.72)),
]

// MARK: - Drawing

/// Everything is laid out on a 1024-unit canvas (the largest icon slot) and
/// scaled to the target size, so each size is redrawn from the shapes rather
/// than shrunk from a big bitmap — that is what keeps the 16/32 px icons crisp.
///
/// `scale` is passed in because shadows ignore the canvas scaling: Core Graphics
/// measures shadow offset and blur in real pixels, so they're scaled by hand.
func drawIcon(_ p: Palette, scale: CGFloat, detailed: Bool) {
    func shadow(y: CGFloat, blur: CGFloat, alpha: CGFloat) {
        let s = NSShadow()
        s.shadowOffset = NSSize(width: 0, height: y * scale)
        s.shadowBlurRadius = blur * scale
        s.shadowColor = NSColor(white: 0, alpha: alpha)
        s.set()
    }

    // Body: Apple's macOS icon grid — an 824×824 rounded square centred on the
    // 1024 canvas, leaving 100 units of margin for the drop shadow.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    // A gradient fill clips to the path, which would clip its own shadow away,
    // so cast the shadow with a plain fill first and lay the gradient on top.
    NSGraphicsContext.saveGraphicsState()
    shadow(y: -10, blur: 20, alpha: 0.30)
    p.backgroundBottom.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: p.backgroundTop, ending: p.backgroundBottom)!.draw(in: body, angle: -90)

    let boardRect = NSRect(x: 322, y: 200, width: 380, height: 520)

    // Back card: the same sheet, tilted, so its corners peek out behind the
    // front one — a stack of past clips.
    NSGraphicsContext.saveGraphicsState()
    let tilt = NSAffineTransform()
    tilt.translateX(by: boardRect.midX, yBy: boardRect.midY)
    tilt.rotate(byDegrees: 9)
    tilt.translateX(by: -boardRect.midX, yBy: -boardRect.midY)
    tilt.concat()
    p.backCard.setFill()
    NSBezierPath(roundedRect: boardRect, xRadius: 50, yRadius: 50).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Front board, lifted off the back card by a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    shadow(y: -6, blur: 18, alpha: 0.22)
    p.board.setFill()
    NSBezierPath(roundedRect: boardRect, xRadius: 50, yRadius: 50).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Clip: a wide base straddling the board's top edge, plus a round knob.
    let clip = NSBezierPath(roundedRect: NSRect(x: 412, y: 680, width: 200, height: 84),
                            xRadius: 28, yRadius: 28)
    clip.append(NSBezierPath(roundedRect: NSRect(x: 467, y: 740, width: 90, height: 90),
                             xRadius: 45, yRadius: 45))
    if detailed {
        // The knob's hole. Wound the opposite way to the two shapes above, so the
        // default (non-zero) fill rule cuts it out instead of filling it.
        clip.append(NSBezierPath(ovalIn: NSRect(x: 495, y: 780, width: 34, height: 34)).reversed)
    }
    p.clip.setFill()
    clip.fill()

    // Text lines. Below ~32 px they blur into a grey smear, so small sizes keep
    // only the silhouette.
    if detailed {
        p.lines.setFill()
        for (y, width) in [(CGFloat(530), CGFloat(260)), (445, 260), (360, 170)] {
            NSBezierPath(roundedRect: NSRect(x: 382, y: y, width: width, height: 34),
                         xRadius: 17, yRadius: 17).fill()
        }
    }
}

/// Renders into a bitmap of exactly `pixels`×`pixels`. Drawing into our own
/// CGContext (instead of NSImage.lockFocus) means a Retina screen can't quietly
/// double the output resolution.
func renderIcon(_ p: Palette, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawIcon(p, scale: scale, detailed: pixels > 32)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw NSError(domain: "make_app_icon", code: 1) }
    try data.write(to: url)
}

// MARK: - Modes

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root

/// One row per style. Each row shows the icon at 256/64/32/16 px, drawn 1:1 in
/// real pixels, first on a light background and then on a dark one (Finder and
/// the Dock can be either).
func preview() throws {
    let sizes = [256, 64, 32, 16]
    let pad = 40, labelWidth = 150
    let halfWidth = sizes.reduce(0, +) + pad * (sizes.count + 1)
    let rowHeight = sizes[0] + pad * 2
    let width = labelWidth + halfWidth * 2
    let height = rowHeight * palettes.count

    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none   // show small sizes exactly as rendered
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    NSColor(white: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: labelWidth + halfWidth, height: height).fill()
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(x: labelWidth + halfWidth, y: 0, width: halfWidth, height: height).fill()

    for (row, palette) in palettes.enumerated() {
        let rowY = height - rowHeight * (row + 1)   // first style at the top
        let midY = rowY + rowHeight / 2
        NSAttributedString(string: palette.name, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: 20, y: midY - 16))

        for half in 0..<2 {
            var x = labelWidth + halfWidth * half + pad
            for size in sizes {
                let image = renderIcon(palette, pixels: size)
                ctx.draw(image, in: CGRect(x: x, y: midY - size / 2, width: size, height: size))
                x += size + pad
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    let outDir = repoRoot.appendingPathComponent("build/icon-previews")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let out = outDir.appendingPathComponent("compare.png")
    try writePNG(ctx.makeImage()!, to: out)
    print("Wrote \(out.path)")
}

/// Writes the asset catalog Xcode compiles into AppIcon.icns. XcodeGen's macOS
/// preset already sets ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon, so the
/// set's name is what connects it to the build — no project.yml change needed.
func install(_ palette: Palette) throws {
    let catalog = repoRoot.appendingPathComponent("shell/Clipd/Assets.xcassets")
    let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

    let info: [String: Any] = ["author": "xcode", "version": 1]
    var images: [[String: String]] = []
    // macOS wants five point sizes, each at 1x and 2x (so 10 files, 16–1024 px).
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try writePNG(renderIcon(palette, pixels: points * scale),
                         to: iconSet.appendingPathComponent(name))
            images.append(["filename": name, "idiom": "mac",
                           "scale": "\(scale)x", "size": "\(points)x\(points)"])
        }
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        // Sorted keys keep the output identical run to run, so re-running the
        // script doesn't produce a noisy diff.
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
    try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
    try writeJSON(["images": images, "info": info],
                  to: iconSet.appendingPathComponent("Contents.json"))
    print("Installed '\(palette.name)' into \(iconSet.path)")
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
let styleNames = palettes.map(\.name).joined(separator: "|")
do {
    switch (args.first, args.count) {
    case ("preview", 1):
        try preview()
    case ("install", 2):
        guard let palette = palettes.first(where: { $0.name == args[1] }) else {
            FileHandle.standardError.write("Unknown style '\(args[1])'. Use \(styleNames).\n".data(using: .utf8)!)
            exit(1)
        }
        try install(palette)
    default:
        FileHandle.standardError.write("""
            Usage: swift scripts/make_app_icon.swift preview
                   swift scripts/make_app_icon.swift install <\(styleNames)>

            """.data(using: .utf8)!)
        exit(1)
    }
} catch {
    FileHandle.standardError.write("make_app_icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
