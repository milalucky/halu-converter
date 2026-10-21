import AppKit

/// One slice of the wheel: a tool plus preset settings.
struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let tool: Tool
    var configure: (inout ToolSettings) -> Void = { _ in }

    /// Shown in the wheel's center while hovering this slice.
    var caption: String {
        switch tool {
        case .convertImage, .convertVideo, .convertAudio: "Convert to \(title)"
        case .pdfToImages: "Pages to \(title)"
        case .compressPDF: title == "Light" ? "Compress, keep text" : "Compress PDF"
        case .compressVideo: "Compress to \(title)"
        default: tool.title
        }
    }

    /// Actions offered for the dragged files, at most 8 so slices stay readable.
    static func actions(for files: [InputFile]) -> [QuickAction] {
        let kinds = Set(files.map(\.kind))
        var actions: [QuickAction]

        if kinds == [.image] {
            let source = files.count == 1 ? ImageFormat(url: files[0].url) : nil
            let formats = [ImageFormat.jpeg, .png, .heic, .avif].filter { $0 != source && ImageFormat.writable.contains($0) }
            actions = formats.map { format in
                QuickAction(title: format.label, symbol: "photo", tool: .convertImage) { $0.imageFormat = format; $0.quality = 0.85 }
            }
            actions += [
                QuickAction(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", tool: .compressImage) { $0.quality = 0.7 },
                QuickAction(title: "Resize", symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", tool: .compressImage) {
                    $0.quality = 0.9; $0.resizeEnabled = true; $0.maxDimension = 2048
                },
                QuickAction(title: files.count == 1 ? "PDF" : "One PDF", symbol: "doc.richtext", tool: .mergePDF),
            ]
        } else if kinds == [.pdf] {
            actions = [
                QuickAction(title: "Compress", symbol: "doc.zipper", tool: .compressPDF) { $0.pdfCompression = .balanced },
                QuickAction(title: "Light", symbol: "text.viewfinder", tool: .compressPDF) { $0.pdfCompression = .smart },
                QuickAction(title: "Split", symbol: "scissors", tool: .splitPDF) { $0.splitMode = .everyPage },
                QuickAction(title: "PNG", symbol: "photo.stack", tool: .pdfToImages) { $0.pdfImageFormat = .png },
                QuickAction(title: "JPEG", symbol: "photo.stack", tool: .pdfToImages) { $0.pdfImageFormat = .jpeg },
            ]
            if files.count > 1 {
                actions.insert(QuickAction(title: "Merge", symbol: "doc.on.doc", tool: .mergePDF), at: 0)
            }
        } else if kinds == [.image, .pdf] {
            actions = [QuickAction(title: "Merge", symbol: "doc.on.doc", tool: .mergePDF)]
        } else if kinds == [.video] {
            let isMP4 = files.count == 1 && files[0].url.pathExtension.lowercased() == "mp4"
            let container: VideoContainer = isMP4 ? .mov : .mp4
            actions = [
                QuickAction(title: "720p", symbol: "film", tool: .compressVideo) { $0.videoPreset = .p720 },
                QuickAction(title: "HEVC", symbol: "film.stack", tool: .compressVideo) { $0.videoPreset = .hevc1080 },
                QuickAction(title: container.label, symbol: "arrow.triangle.2.circlepath", tool: .convertVideo) { $0.videoContainer = container },
                QuickAction(title: "GIF", symbol: "sparkles.tv", tool: .videoToGIF) { $0.gifFPS = 12; $0.gifWidth = 480 },
                QuickAction(title: "Audio", symbol: "waveform", tool: .extractAudio),
            ]
        } else if kinds == [.audio] {
            let source = files.count == 1 ? files[0].url.pathExtension.lowercased() : ""
            actions = AudioFormat.allCases.filter { $0.rawValue != source }.map { format in
                QuickAction(title: format.label, symbol: "music.note", tool: .convertAudio) { $0.audioFormat = format }
            }
        } else {
            actions = []
        }
        return Array(actions.prefix(8))
    }
}

enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, option, control, command
    var id: String { rawValue }

    static let defaultsKey = "triggerKey"
    static var current: TriggerKey {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TriggerKey.init) ?? .shift
    }

    var label: String {
        switch self {
        case .shift: "⇧ Shift"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        }
    }
}
