import AppKit

/// One petal of the wheel: a tool plus preset settings.
struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let tool: Tool
    var configure: (inout ToolSettings) -> Void = { _ in }

    /// Shown in the wheel's center while hovering this petal.
    var caption: String {
        switch tool {
        case .convertImage, .convertVideo, .convertAudio, .convertDocument, .convertPresentation,
             .convertSpreadsheet, .convertSubtitle: "Convert to \(title)"
        case .pdfToImages: "Pages to \(title)"
        case .compressPDF: title == "Light" ? "Compress, keep text" : "Compress PDF"
        case .compressVideo: "Compress to \(title)"
        case .makeArchive: "Pack into \(title)"
        case .makeSketch:
            switch title {
            case "Colours": "DXF, a file per colour"
            case "Pieces": "DXF, a file per piece"
            case "Lines": "DXF with polylines"
            default: "Sketch for CAD (DXF)"
            }
        default: tool.title
        }
    }

    /// Actions offered for the dragged files, at most 8 so petals stay readable.
    static func actions(for files: [InputFile]) -> [QuickAction] {
        let kinds = Set(files.map(\.kind))
        let sourceExt = files.count == 1 ? files[0].url.pathExtension.lowercased() : ""
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
                QuickAction(title: "DXF", symbol: "pencil.and.outline", tool: .makeSketch),
            ]
        } else if kinds == [.pdf] {
            actions = [
                QuickAction(title: "Compress", symbol: "doc.zipper", tool: .compressPDF) { $0.pdfCompression = .balanced },
                QuickAction(title: "Light", symbol: "text.viewfinder", tool: .compressPDF) { $0.pdfCompression = .smart },
                QuickAction(title: "Split", symbol: "scissors", tool: .splitPDF) { $0.splitMode = .everyPage },
                QuickAction(title: "PNG", symbol: "photo.stack", tool: .pdfToImages) { $0.pdfImageFormat = .png },
                QuickAction(title: "JPEG", symbol: "photo.stack", tool: .pdfToImages) { $0.pdfImageFormat = .jpeg },
                QuickAction(title: "DXF", symbol: "pencil.and.outline", tool: .makeSketch),
            ]
            if files.count > 1 {
                actions.insert(QuickAction(title: "Merge", symbol: "doc.on.doc", tool: .mergePDF), at: 0)
            }
        } else if kinds == [.vector] {
            actions = [
                QuickAction(title: "DXF", symbol: "pencil.and.outline", tool: .makeSketch),
                QuickAction(title: "Colours", symbol: "paintpalette", tool: .makeSketch) { $0.sketchSplit = .byColor },
                QuickAction(title: "Pieces", symbol: "square.on.square.dashed", tool: .makeSketch) { $0.sketchSplit = .byPiece },
                QuickAction(title: "Lines", symbol: "point.topleft.down.to.point.bottomright.curvepath", tool: .makeSketch) {
                    $0.sketchCurves = .polylines
                },
            ]
        } else if kinds == [.image, .pdf] {
            actions = [QuickAction(title: "Merge", symbol: "doc.on.doc", tool: .mergePDF)]
        } else if kinds == [.video] {
            let container: VideoContainer = sourceExt == "mp4" ? .mov : .mp4
            actions = [
                QuickAction(title: "720p", symbol: "film", tool: .compressVideo) { $0.videoPreset = .p720 },
                QuickAction(title: "HEVC", symbol: "film.stack", tool: .compressVideo) { $0.videoPreset = .hevc1080 },
                QuickAction(title: container.label, symbol: "arrow.triangle.2.circlepath", tool: .convertVideo) { $0.videoContainer = container },
                QuickAction(title: "GIF", symbol: "sparkles.tv", tool: .videoToGIF) { $0.gifFPS = 12; $0.gifWidth = 480 },
                QuickAction(title: "Audio", symbol: "waveform", tool: .extractAudio),
            ]
        } else if kinds == [.audio] {
            actions = AudioFormat.allCases.filter { $0.fileExtension != sourceExt }.map { format in
                QuickAction(title: format.label, symbol: format == .flac || format == .alac ? "waveform.badge.plus" : "music.note",
                            tool: .convertAudio) { $0.audioFormat = format }
            }
        } else if kinds == [.document] {
            let symbols: [DocumentFormat: String] = [.pdf: "doc.richtext", .docx: "doc.text", .pages: "doc.append", .md: "number",
                                                     .txt: "text.alignleft", .rtf: "textformat", .html: "chevron.left.forwardslash.chevron.right",
                                                     .odt: "doc", .doc: "doc.text"]
            actions = [DocumentFormat.pdf, .docx, .pages, .md, .txt, .rtf, .html, .odt]
                .filter { $0.rawValue != sourceExt && !(sourceExt == "markdown" && $0 == .md) }
                .map { format in
                    QuickAction(title: format.label, symbol: symbols[format] ?? "doc", tool: .convertDocument) { $0.documentFormat = format }
                }
        } else if kinds == [.presentation] {
            let symbols: [SlidesFormat: String] = [.pdf: "doc.richtext", .pptx: "rectangle.on.rectangle.angled", .key: "play.rectangle",
                                                   .png: "photo.stack", .jpeg: "photo.stack"]
            actions = SlidesFormat.allCases.filter { $0.rawValue != sourceExt }.map { format in
                QuickAction(title: format.label.replacingOccurrences(of: " slides", with: ""), symbol: symbols[format] ?? "doc",
                            tool: .convertPresentation) { $0.slidesFormat = format }
            }
        } else if kinds == [.spreadsheet] {
            let symbols: [SheetFormat: String] = [.xlsx: "tablecells", .numbers: "chart.bar.doc.horizontal", .csv: "list.bullet.rectangle",
                                                  .tsv: "list.bullet.rectangle", .pdf: "doc.richtext"]
            actions = SheetFormat.allCases.filter { $0.rawValue != sourceExt }.map { format in
                QuickAction(title: format.label, symbol: symbols[format] ?? "tablecells", tool: .convertSpreadsheet) { $0.sheetFormat = format }
            }
        } else if kinds == [.archive] {
            actions = [QuickAction(title: "Extract", symbol: "shippingbox.and.arrow.backward", tool: .extractArchive)]
        } else if kinds == [.subtitle] {
            actions = SubtitleFormat.allCases.filter { $0.rawValue != sourceExt }.map { format in
                QuickAction(title: format.label, symbol: "captions.bubble", tool: .convertSubtitle) { $0.subtitleFormat = format }
            }
        } else if kinds == [.folder] {
            actions = ArchiveFormat.allCases.map { format in
                QuickAction(title: format.label, symbol: "archivebox", tool: .makeArchive) { $0.archiveFormat = format }
            }
        } else {
            actions = []
        }
        return Array(actions.prefix(8))
    }
}

/// Small "moons" around the wheel: things you can do with any file.
enum FileAction: String, CaseIterable, Identifiable {
    case airDrop, zip, copyPath
    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .zip: "ZIP"
        case .copyPath: "Copy Path"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "dot.radiowaves.left.and.right"
        case .zip: "archivebox"
        case .copyPath: "link"
        }
    }

    @MainActor
    func perform(on urls: [URL]) {
        switch self {
        case .airDrop:
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .zip:
            AppModel.shared.runQuick(QuickAction(title: "ZIP", symbol: symbol, tool: .makeArchive) { $0.archiveFormat = .zip }, urls: urls)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            ToastController.shared.flash(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied", symbol: "link")
        }
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
