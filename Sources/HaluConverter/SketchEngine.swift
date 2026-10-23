import AppKit
import ImageIO

enum SketchSplit: String, CaseIterable, Identifiable {
    case oneFile, byColor, byPiece
    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneFile: "One file"
        case .byColor: "File per colour"
        case .byPiece: "File per piece"
        }
    }
}

/// SVG, PDF, Illustrator and bitmap logos → DXF sketches for CAD (Shapr3D, Fusion, Onshape…).
/// Vectors keep their exact curves; bitmaps are traced. Output is in millimetres, bottom-left at 0,0.
enum SketchEngine {
    static func toDXF(_ url: URL, settings s: ToolSettings, outputDir: URL?) throws -> [URL] {
        let pages = try read(url, settings: s)
        let width = s.sketchFitWidth && s.sketchWidth > 0 ? s.sketchWidth : nil
        var outputs: [URL] = []
        for (index, sketch) in pages.enumerated() {
            let suffix = pages.count > 1 ? " – page \(index + 1)" : ""
            outputs += try write(sketch.placed(width: width), for: url, suffix: suffix, settings: s, outputDir: outputDir)
        }
        return outputs
    }

    // MARK: - Reading

    private static func read(_ url: URL, settings s: ToolSettings) throws -> [Sketch] {
        switch url.pathExtension.lowercased() {
        case "svg":
            let result = try SVGImporter.read(try Data(contentsOf: url))
            if result.sketch.isEmpty { throw noShapes(textRuns: result.skippedText) }
            return [result.sketch]
        case "pdf", "ai":
            let pages = try PDFVectorImporter.read(url).filter { !$0.sketch.isEmpty || $0.textRuns > 0 }
            guard !pages.isEmpty else { throw noShapes(textRuns: 0) }
            let drawn = pages.filter { !$0.sketch.isEmpty }
            guard !drawn.isEmpty else { throw noShapes(textRuns: pages.map(\.textRuns).reduce(0, +)) }
            return drawn.map(\.sketch)
        default:
            let (bitmap, mmPerPixel) = try loadBitmap(url)
            let shapes = Tracer.trace(bitmap, detail: s.traceDetail, separateColors: s.traceColors)
            let sketch = Sketch(shapes: shapes).transformed(.scale(mmPerPixel, -mmPerPixel))
            guard !sketch.isEmpty else {
                throw HaluError.failed("No shapes found. Logos on a plain or transparent background trace best.")
            }
            return [sketch]
        }
    }

    private static func noShapes(textRuns: Int) -> HaluError {
        textRuns > 0
            ? .failed("Only text was found. Convert it to outlines first (Illustrator: Type → Create Outlines; Figma: Flatten).")
            : .failed("No shapes found in this file.")
    }

    /// Decodes the image at a size that traces well (1000–2400 px on the long side), alpha not premultiplied.
    private static func loadBitmap(_ url: URL) throws -> (Bitmap, Double) {
        let image = try ImageEngine.load(url, maxDimension: 2400)
        let longest = Double(max(image.width, image.height))
        let k = longest < 1000 ? 1000 / longest : 1
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw HaluError.unreadable(url) }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
        }
        // Sized as if the original were 96 dpi; "Width" in the options sets the real size.
        let mmPerPixel = 25.4 / 96 * Double(image.width) / Double(w)
        return (Bitmap(width: w, height: h, pixels: pixels), mmPerPixel)
    }

    // MARK: - Writing

    private static func write(_ sketch: Sketch, for url: URL, suffix: String, settings s: ToolSettings, outputDir: URL?) throws -> [URL] {
        let groups = sketch.colorGroups
        let writer = DXFWriter(curves: s.sketchCurves)
        let names = layerNames(groups)

        var files: [(name: String, layers: [DXFWriter.Layer])] = []
        switch s.sketchSplit {
        case .oneFile:
            break
        case .byColor where groups.count > 1:
            files = zip(groups, names).map { group, name in (name: name, layers: [DXFWriter.Layer(name: name, contours: group.contours)]) }
        case .byPiece:
            var all: [DXFWriter.Layer] = []
            for (group, name) in zip(groups, names) {
                for piece in Sketch.pieces(of: group.contours) { all.append(DXFWriter.Layer(name: name, contours: piece)) }
            }
            if all.count > 1 {
                let digits = String(all.count).count
                let tagColors = groups.count > 1
                files = all.enumerated().map { index, layer in
                    let number = String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
                    let color = tagColors ? " " + (layer.name.split(separator: " ").last.map(String.init) ?? "") : ""
                    return (name: "Piece \(number)\(color)", layers: [layer])
                }
            }
        default:
            break
        }

        if files.isEmpty {
            let output = OutputNamer.file(for: url, suffix: suffix, ext: "dxf", in: outputDir)
            let layers = zip(groups, names).map { DXFWriter.Layer(name: $1, contours: $0.contours) }
            try save(writer.data(layers: layers), to: output)
            return [output]
        }
        let folder = try OutputNamer.folder(for: url, suffix: suffix + (s.sketchSplit == .byPiece ? " pieces" : " colours"), in: outputDir)
        var outputs = [folder]
        for file in files {
            let output = folder.appendingPathComponent(file.name).appendingPathExtension("dxf")
            try save(writer.data(layers: file.layers), to: output)
            outputs.append(output)
        }
        return outputs
    }

    /// "Colour 1 E85D2A", "Colour 2 1A1A1A", "Lines 000000" for strokes.
    private static func layerNames(_ groups: [SketchShape]) -> [String] {
        var fillIndex = 0
        return groups.map { group in
            let hex = group.color?.hex ?? "000000"
            if !group.filled { return "Lines \(hex)" }
            fillIndex += 1
            return "Colour \(fillIndex) \(hex)"
        }
    }

    private static func save(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) } catch { throw HaluError.writeFailed(url) }
    }
}
