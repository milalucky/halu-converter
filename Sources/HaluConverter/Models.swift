import SwiftUI
import UniformTypeIdentifiers

enum FileKind: Hashable {
    case image, pdf, video, audio, other

    init(url: URL) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { self = .other; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { self = .other }
    }

    var label: String {
        switch self {
        case .image: "image"
        case .pdf: "PDF"
        case .video: "video"
        case .audio: "audio"
        case .other: "file"
        }
    }
}

struct InputFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64

    init(url: URL) {
        self.url = url
        self.kind = FileKind(url: url)
        self.size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

enum ToolCategory: String, CaseIterable, Identifiable {
    case convert = "Convert"
    case compress = "Compress"
    case organize = "Organize"
    var id: String { rawValue }
}

enum Tool: String, CaseIterable, Identifiable {
    case convertImage, compressImage
    case mergePDF, splitPDF, compressPDF, pdfToImages
    case compressVideo, convertVideo, videoToGIF, extractAudio
    case convertAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convertImage: "Convert Image"
        case .compressImage: "Compress Image"
        case .mergePDF: "Combine into PDF"
        case .splitPDF: "Split PDF"
        case .compressPDF: "Compress PDF"
        case .pdfToImages: "PDF to Images"
        case .compressVideo: "Compress Video"
        case .convertVideo: "Convert Video"
        case .videoToGIF: "Video to GIF"
        case .extractAudio: "Extract Audio"
        case .convertAudio: "Convert Audio"
        }
    }

    var subtitle: String {
        switch self {
        case .convertImage: "JPG, PNG, HEIC, AVIF…"
        case .compressImage: "Smaller photos, same look"
        case .mergePDF: "Merge PDFs and images"
        case .splitPDF: "Every page or by ranges"
        case .compressPDF: "Shrink for email & upload"
        case .pdfToImages: "Export pages as PNG/JPG"
        case .compressVideo: "H.264 / HEVC presets"
        case .convertVideo: "MP4 ⇄ MOV"
        case .videoToGIF: "Animated, looping GIF"
        case .extractAudio: "Save soundtrack as M4A"
        case .convertAudio: "M4A, WAV, AIFF, CAF"
        }
    }

    var symbol: String {
        switch self {
        case .convertImage: "photo.on.rectangle.angled"
        case .compressImage: "arrow.down.right.and.arrow.up.left"
        case .mergePDF: "doc.on.doc"
        case .splitPDF: "scissors"
        case .compressPDF: "doc.zipper"
        case .pdfToImages: "photo.stack"
        case .compressVideo: "film"
        case .convertVideo: "arrow.triangle.2.circlepath"
        case .videoToGIF: "sparkles.tv"
        case .extractAudio: "waveform"
        case .convertAudio: "music.note"
        }
    }

    var tint: Color {
        switch category {
        case .convert: .blue
        case .compress: .green
        case .organize: .orange
        }
    }

    var category: ToolCategory {
        switch self {
        case .convertImage, .pdfToImages, .convertVideo, .videoToGIF, .extractAudio, .convertAudio: .convert
        case .compressImage, .compressPDF, .compressVideo: .compress
        case .mergePDF, .splitPDF: .organize
        }
    }

    /// Batch tools consume all inputs at once and produce a single result.
    var isBatch: Bool { self == .mergePDF }

    func accepts(_ files: [InputFile]) -> Bool {
        guard !files.isEmpty else { return false }
        let kinds = Set(files.map(\.kind))
        switch self {
        case .convertImage, .compressImage:
            return kinds == [.image]
        case .mergePDF:
            return kinds.isSubset(of: [.image, .pdf]) && !(files.count == 1 && kinds == [.pdf])
        case .splitPDF, .compressPDF, .pdfToImages:
            return kinds == [.pdf]
        case .compressVideo, .convertVideo, .videoToGIF, .extractAudio:
            return kinds == [.video]
        case .convertAudio:
            return kinds == [.audio]
        }
    }
}

enum CompressImageFormat: String, CaseIterable, Identifiable {
    case original, jpeg, heic, avif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Keep format"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }
}

enum SplitMode: String, CaseIterable, Identifiable {
    case everyPage, ranges
    var id: String { rawValue }
    var label: String { self == .everyPage ? "Every page" : "Custom ranges" }
}

/// All tool options in one value type, so a snapshot can be handed to background work.
struct ToolSettings {
    var imageFormat: ImageFormat = .jpeg
    var quality: Double = 0.75
    var resizeEnabled = false
    var maxDimension: Double = 2048
    var compressFormat: CompressImageFormat = .original
    var splitMode: SplitMode = .everyPage
    var splitRanges = ""
    var pdfCompression: PDFCompressionLevel = .balanced
    var pdfImageFormat: ImageFormat = .png
    var pdfDPI: Double = 150
    var videoPreset: VideoPreset = .hevc1080
    var videoContainer: VideoContainer = .mp4
    var gifFPS: Double = 12
    var gifWidth: Double = 480
    var audioFormat: AudioFormat = .m4a
}

enum HaluError: LocalizedError {
    case unreadable(URL)
    case writeFailed(URL)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Can't read “\(url.lastPathComponent)”. The format may not be supported."
        case .writeFailed(let url): "Couldn't write “\(url.lastPathComponent)”."
        case .failed(let message): message
        }
    }
}

enum OutputNamer {
    /// A free file URL like `photo-compressed.jpg`, `photo-compressed 2.jpg`, …
    static func file(for input: URL, suffix: String, ext: String, in dir: URL?) -> URL {
        let folder = dir ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    /// Creates and returns a fresh folder like `report-pages`.
    static func folder(for input: URL, suffix: String, in dir: URL?) throws -> URL {
        let parent = dir ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(i)", isDirectory: true)
            i += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
