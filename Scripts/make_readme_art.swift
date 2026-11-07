// Composes the README images from raw screenshots.
// Usage: swift Scripts/make_readme_art.swift <shots dir> <app icon .icns> <out dir>
// Expects in <shots dir>: wheel-image.png, wheel-docs.png, wheel-pdf.png, wheel-sheet.png (transparent wheel captures),
// window-empty.png, window-files.png (window captures) and toast.png.
import AppKit

let shots = URL(fileURLWithPath: CommandLine.arguments[1])
let icon = NSImage(contentsOfFile: CommandLine.arguments[2])!
let out = URL(fileURLWithPath: CommandLine.arguments[3])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func shot(_ name: String) -> NSImage { NSImage(contentsOf: shots.appendingPathComponent(name))! }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Dark sunset backdrop with soft orange and violet glows, matching the wheel's palette.
func drawBackdrop(_ size: NSSize) {
    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [rgb(0.10, 0.06, 0.12), rgb(0.06, 0.06, 0.13)])!.draw(in: rect, angle: -30)
    for (x, y, r, color) in [(0.28, 0.72, 0.55, rgb(1.0, 0.45, 0.2, 0.30)), (0.78, 0.25, 0.6, rgb(0.55, 0.35, 1.0, 0.28)),
                             (0.6, 0.85, 0.35, rgb(1.0, 0.35, 0.55, 0.18))] {
        let center = NSPoint(x: size.width * x, y: size.height * y)
        NSGradient(colors: [color, color.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: size.width * r, options: [])
    }
}

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

func text(_ string: String, _ font: NSFont, _ color: NSColor, at point: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: point)
}

func render(_ name: String, _ size: NSSize, jpeg: Bool = true, _ draw: (NSSize) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])! : rep.representation(using: .png, properties: [:])!
    try data.write(to: out.appendingPathComponent(name))
}

/// Draws an image so it fits `rect`, keeping its aspect ratio.
func place(_ image: NSImage, in rect: NSRect) {
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
}

// Hero: icon, name, tagline, and the flower.
try render("hero.jpg", NSSize(width: 2400, height: 1200)) { size in
    drawBackdrop(size)
    icon.draw(in: NSRect(x: 170, y: 740, width: 190, height: 190))
    text("Halu Converter", font(118, .heavy), .white, at: NSPoint(x: 170, y: 560), kern: -2)
    text("Drag a file. Hold Shift. Pick a petal.", font(50, .semibold), rgb(1, 0.78, 0.62), at: NSPoint(x: 176, y: 470))
    text("Convert, compress, split and merge any file", font(38, .medium), NSColor.white.withAlphaComponent(0.62), at: NSPoint(x: 176, y: 390))
    text("right where you are. No window, no upload.", font(38, .medium), NSColor.white.withAlphaComponent(0.62), at: NSPoint(x: 176, y: 340))
    var x: CGFloat = 176
    for chip in ["Images", "PDF", "Video", "Audio", "Docs", "Slides", "CAD"] {
        let attributed = NSAttributedString(string: chip, attributes: [.font: font(30, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        let width = attributed.size().width + 44
        let pill = NSBezierPath(roundedRect: NSRect(x: x, y: 200, width: width, height: 64), xRadius: 32, yRadius: 32)
        NSColor.white.withAlphaComponent(0.09).setFill(); pill.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke(); pill.lineWidth = 2; pill.stroke()
        attributed.draw(at: NSPoint(x: x + 22, y: 214))
        x += width + 16
    }
    place(shot("wheel-image.png"), in: NSRect(x: 1220, y: 40, width: 1120, height: 1120))
}

// Gallery: one flower per file type.
try render("flowers.jpg", NSSize(width: 2400, height: 980)) { size in
    drawBackdrop(size)
    for (i, (file, label)) in [("wheel-docs.png", "Documents"), ("wheel-pdf.png", "PDF · AirDrop moon"), ("wheel-sheet.png", "Spreadsheets")].enumerated() {
        let x = CGFloat(i) * 800
        place(shot(file), in: NSRect(x: x + 20, y: 150, width: 760, height: 760))
        let attributed = NSAttributedString(string: label, attributes: [.font: font(40, .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        attributed.draw(at: NSPoint(x: x + 400 - attributed.size().width / 2, y: 70))
    }
}

// Toast: the progress card cropped from its transparent panel, on the backdrop.
try render("toast.jpg", NSSize(width: 1400, height: 340)) { size in
    drawBackdrop(size)
    let toast = shot("toast.png")
    // The card sits in the lower part of a taller transparent panel; keep its bottom 45%, at 1:1 pixels (2× points).
    let crop = NSRect(x: 0, y: 0, width: toast.size.width, height: toast.size.height * 0.45)
    let target = NSRect(x: (size.width - toast.size.width * 2) / 2, y: (size.height - crop.height * 2) / 2,
                        width: toast.size.width * 2, height: crop.height * 2)
    toast.draw(in: target, from: crop, operation: .sourceOver, fraction: 1)
}

// Windows keep their own shadow and transparency.
for name in ["window-files", "window-empty"] {
    let image = shot(name + ".png")
    let width: CGFloat = 1800
    try render(name + ".png", NSSize(width: width, height: (image.size.height / image.size.width * width).rounded()), jpeg: false) { size in
        image.draw(in: NSRect(origin: .zero, size: size))
    }
}
