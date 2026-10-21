import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, avif, webp, tiff, gif, bmp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        case .webp: .webP
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    var isLossy: Bool { [.jpeg, .heic, .avif, .webp].contains(self) }
    var supportsAlpha: Bool { ![.jpeg, .bmp].contains(self) }

    /// Formats this Mac's ImageIO can actually encode.
    static let writable: [ImageFormat] = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { ids.contains($0.utType.identifier) }
    }()

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if let match = ImageFormat.allCases.first(where: { $0.fileExtension == ext || $0.rawValue == ext }) {
            self = match
        } else if ext == "jpeg" {
            self = .jpeg
        } else if ext == "tif" {
            self = .tiff
        } else {
            return nil
        }
    }
}

enum ImageEngine {
    /// Decodes an image with EXIF orientation applied, optionally downscaled.
    static func load(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw HaluError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        let target = longest > 0 ? min(maxDimension ?? longest, longest) : (maxDimension ?? 8192)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw HaluError.unreadable(url)
        }
        return image
    }

    static func write(_ image: CGImage, as format: ImageFormat, quality: Double, to url: URL) throws {
        var image = image
        if !format.supportsAlpha, hasAlpha(image) {
            image = flattenOnWhite(image)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw HaluError.writeFailed(url)
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw HaluError.writeFailed(url) }
    }

    static func convert(_ url: URL, to format: ImageFormat, quality: Double, maxDimension: Int?, outputDir: URL?) throws -> URL {
        let image = try load(url, maxDimension: maxDimension)
        let sameName = format == ImageFormat(url: url)
        let output = OutputNamer.file(for: url, suffix: sameName ? "-converted" : "", ext: format.fileExtension, in: outputDir)
        try write(image, as: format, quality: quality, to: output)
        return output
    }

    static func compress(_ url: URL, format choice: CompressImageFormat, quality: Double, maxDimension: Int?, outputDir: URL?) throws -> URL {
        let format: ImageFormat
        switch choice {
        case .original:
            let original = ImageFormat(url: url) ?? .jpeg
            format = ImageFormat.writable.contains(original) ? original : .jpeg
        case .jpeg: format = .jpeg
        case .heic: format = .heic
        case .avif: format = .avif
        }
        let image = try load(url, maxDimension: maxDimension)
        let output = OutputNamer.file(for: url, suffix: "-compressed", ext: format.fileExtension, in: outputDir)
        try write(image, as: format, quality: quality, to: output)
        return output
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func flattenOnWhite(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}
