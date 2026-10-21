import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFCompressionLevel: String, CaseIterable, Identifiable {
    case smart, balanced, strong
    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    var detail: String {
        switch self {
        case .smart: "Recompresses embedded images. Text stays selectable."
        case .balanced: "Pages become 150 dpi images. Text is no longer selectable."
        case .strong: "Pages become 96 dpi images. Smallest file, text not selectable."
        }
    }
}

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw HaluError.unreadable(url) }
        if doc.isLocked { throw HaluError.failed("“\(url.lastPathComponent)” is password-protected.") }
        return doc
    }

    /// Combines PDFs and images (one image per page) in the given order.
    static func merge(_ urls: [URL], outputDir: URL?, progress: @Sendable (Double) -> Void) throws -> URL {
        let result = PDFDocument()
        for (index, url) in urls.enumerated() {
            if FileKind(url: url) == .pdf {
                let doc = try open(url)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage {
                        result.insert(page, at: result.pageCount)
                    }
                }
            } else {
                let image = try ImageEngine.load(url)
                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let page = PDFPage(image: nsImage) else { throw HaluError.unreadable(url) }
                result.insert(page, at: result.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        let name = urls.count == 1 ? "" : "-merged"
        let output = OutputNamer.file(for: urls[0], suffix: name, ext: "pdf", in: outputDir)
        guard result.write(to: output) else { throw HaluError.writeFailed(output) }
        return output
    }

    /// Parses "1-3, 5, 8-" into 1-based page ranges.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw HaluError.failed("Enter page ranges, e.g. 1-3, 5, 8-") }
        return try parts.map { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int?
            let upper: Int?
            switch bounds.count {
            case 1: lower = Int(bounds[0]); upper = lower
            case 2: lower = bounds[0].isEmpty ? 1 : Int(bounds[0]); upper = bounds[1].isEmpty ? pageCount : Int(bounds[1])
            default: lower = nil; upper = nil
            }
            guard let lower, let upper, lower >= 1, upper <= pageCount, lower <= upper else {
                throw HaluError.failed("“\(part)” isn't a valid range for a \(pageCount)-page PDF.")
            }
            return lower...upper
        }
    }

    static func split(_ url: URL, mode: SplitMode, ranges text: String, outputDir: URL?, progress: @Sendable (Double) -> Void) throws -> [URL] {
        let doc = try open(url)
        let ranges = mode == .everyPage
            ? (1...max(doc.pageCount, 1)).map { $0...$0 }
            : try parseRanges(text, pageCount: doc.pageCount)
        let folder = try OutputNamer.folder(for: url, suffix: "-split", in: outputDir)
        let base = url.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        for (index, range) in ranges.enumerated() {
            let part = PDFDocument()
            for pageNumber in range {
                if let page = doc.page(at: pageNumber - 1)?.copy() as? PDFPage {
                    part.insert(page, at: part.pageCount)
                }
            }
            let label = range.count == 1 ? "page \(range.lowerBound)" : "pages \(range.lowerBound)-\(range.upperBound)"
            let output = folder.appendingPathComponent("\(base) – \(label).pdf")
            guard part.write(to: output) else { throw HaluError.writeFailed(output) }
            outputs.append(output)
            progress(Double(index + 1) / Double(ranges.count))
        }
        return [folder] + outputs
    }

    static func compress(_ url: URL, level: PDFCompressionLevel, outputDir: URL?, progress: @Sendable (Double) -> Void) throws -> URL {
        let output = OutputNamer.file(for: url, suffix: "-compressed", ext: "pdf", in: outputDir)
        switch level {
        case .smart:
            let doc = try open(url)
            let options: [PDFDocumentWriteOption: Any] = [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: true,
            ]
            guard doc.write(to: output, withOptions: options) else { throw HaluError.writeFailed(output) }
            progress(1)
        case .balanced:
            try rasterize(url, dpi: 150, quality: 0.6, to: output, progress: progress)
        case .strong:
            try rasterize(url, dpi: 96, quality: 0.45, to: output, progress: progress)
        }
        return output
    }

    static func toImages(_ url: URL, format: ImageFormat, dpi: Double, outputDir: URL?, progress: @Sendable (Double) -> Void) throws -> [URL] {
        let doc = try open(url)
        let folder = try OutputNamer.folder(for: url, suffix: "-pages", in: outputDir)
        let base = url.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let image = render(page, dpi: dpi) else { continue }
            let output = folder.appendingPathComponent("\(base) – \(i + 1)").appendingPathExtension(format.fileExtension)
            try ImageEngine.write(image, as: format, quality: 0.9, to: output)
            outputs.append(output)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return [folder] + outputs
    }

    // MARK: - Rendering

    /// Renders a page (rotation applied) onto a white bitmap.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = dpi / 72
        let width = max(Int(size.width * scale), 1)
        let height = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    private static func rasterize(_ url: URL, dpi: Double, quality: Double, to output: URL, progress: @Sendable (Double) -> Void) throws {
        let doc = try open(url)
        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else { throw HaluError.writeFailed(output) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let image = render(page, dpi: dpi) else { continue }
            // Re-encode as JPEG and draw via a JPEG data provider so Quartz embeds the DCT stream as-is.
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            CGImageDestinationFinalize(dest)
            guard let provider = CGDataProvider(data: data),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(jpeg, in: box)
            pdf.endPage()
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        pdf.closePDF()
    }
}
