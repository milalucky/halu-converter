import AppKit
import CoreText

enum DocumentFormat: String, CaseIterable, Identifiable {
    case pdf, docx, pages, doc, rtf, odt, txt, html, md
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word"
        case .pages: "Pages"
        case .doc: "DOC"
        case .rtf: "RTF"
        case .odt: "ODT"
        case .txt: "Text"
        case .html: "HTML"
        case .md: "Markdown"
        }
    }
}

enum SlidesFormat: String, CaseIterable, Identifiable {
    case pdf, pptx, key, png, jpeg
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .pptx: "PowerPoint"
        case .key: "Keynote"
        case .png: "PNG slides"
        case .jpeg: "JPEG slides"
        }
    }
}

enum SheetFormat: String, CaseIterable, Identifiable {
    case xlsx, numbers, csv, tsv, pdf
    var id: String { rawValue }

    var label: String {
        switch self {
        case .xlsx: "Excel"
        case .numbers: "Numbers"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .pdf: "PDF"
        }
    }
}

enum DocumentEngine {
    /// Formats Pages handles better than the system text importer (images, tables, layout).
    private static let richInputs: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "pages"]

    static func convert(_ url: URL, to format: DocumentFormat, outputDir: URL?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let output = OutputNamer.file(for: url, suffix: ext == format.rawValue ? "-converted" : "", ext: format.rawValue, in: outputDir)

        // Pages in or out, or a high-fidelity PDF of a Word-like document: let Pages do it.
        let usePages = ext == "pages" || format == .pages || (format == .pdf && richInputs.contains(ext))
        if usePages && IWork.isInstalled(.pages) {
            if ext == "pages" || ["doc", "docx", "rtf", "txt"].contains(ext) {
                guard format.needsTextPass else {
                    try await IWork.run(.pages, input: url, output: output, as: pagesExportName(format))
                    return output
                }
                // Pages can't write this format directly: export Word, then convert that.
                let word = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
                defer { try? FileManager.default.removeItem(at: word) }
                try await IWork.run(.pages, input: url, output: word, as: "Microsoft Word")
                try await writeNative(read(word), as: format, to: output)
                return output
            }
            // Markdown/HTML/ODT → Pages: make a Word file first, then hand it to Pages.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
            try await writeNative(read(url), as: .docx, to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            try await IWork.run(.pages, input: temp, output: output, as: pagesExportName(format))
            return output
        }
        if ext == "pages" || format == .pages {
            throw HaluError.failed("Pages isn't installed. Get it free from the App Store to convert Pages files.")
        }
        try await writeNative(read(url), as: format, to: output)
        return output
    }

    /// nil means "save as a native Pages document".
    private static func pagesExportName(_ format: DocumentFormat) -> String? {
        switch format {
        case .pages: nil
        case .pdf: "PDF"
        case .txt: "unformatted text"
        case .rtf: "formatted text"
        default: "Microsoft Word"
        }
    }

    // MARK: - Native (no extra apps)

    @MainActor
    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        let bodyFont = NSFont.systemFont(ofSize: 12)
        switch ext {
        case "md", "markdown", "txt":
            guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
                throw HaluError.unreadable(url)
            }
            if ext == "txt" { return NSAttributedString(string: text, attributes: [.font: bodyFont]) }
            let html = Markdown.html(from: text)
            guard let result = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil) else { throw HaluError.unreadable(url) }
            return result
        default:
            do {
                return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            } catch {
                throw HaluError.unreadable(url)
            }
        }
    }

    @MainActor
    static func writeNative(_ text: NSAttributedString, as format: DocumentFormat, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let data: Data
        switch format {
        case .docx: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case .doc: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
        case .rtf: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .odt: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        case .html: data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        case .txt: data = Data(text.string.utf8)
        case .md: data = Data(Markdown.markdown(from: text).utf8)
        case .pdf: try PDFTextRenderer.render(text, to: url); return
        case .pages: throw HaluError.failed("Pages isn't installed.")
        }
        do { try data.write(to: url) } catch { throw HaluError.writeFailed(url) }
    }

    // MARK: - Slides & spreadsheets (Keynote / Numbers)

    static func convertSlides(_ url: URL, to format: SlidesFormat, outputDir: URL?) async throws -> [URL] {
        guard IWork.isInstalled(.keynote) else {
            throw HaluError.failed("Keynote isn't installed. Get it free from the App Store to convert slides.")
        }
        switch format {
        case .png, .jpeg:
            let folder = try OutputNamer.folder(for: url, suffix: "-slides", in: outputDir)
            try await IWork.run(.keynote, input: url, output: folder, as: "slide images",
                                properties: "{image format:\(format == .png ? "PNG" : "JPEG")}")
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return [folder] + files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        default:
            let ext = url.pathExtension.lowercased()
            let output = OutputNamer.file(for: url, suffix: ext == format.rawValue ? "-converted" : "", ext: format.rawValue, in: outputDir)
            let exportName: String? = switch format {
            case .pdf: "PDF"
            case .pptx: "Microsoft PowerPoint"
            default: nil
            }
            try await IWork.run(.keynote, input: url, output: output, as: exportName)
            return [output]
        }
    }

    static func convertSheet(_ url: URL, to format: SheetFormat, outputDir: URL?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let output = OutputNamer.file(for: url, suffix: ext == format.rawValue ? "-converted" : "", ext: format.rawValue, in: outputDir)

        // CSV ⇄ TSV needs no app.
        if ["csv", "tsv"].contains(ext) && [.csv, .tsv].contains(format) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rows = Delimited.parse(text, separator: ext == "tsv" ? "\t" : ",")
            try Delimited.write(rows, separator: format == .tsv ? "\t" : ",").write(to: output, atomically: true, encoding: .utf8)
            return output
        }
        guard IWork.isInstalled(.numbers) else {
            throw HaluError.failed("Numbers isn't installed. Get it free from the App Store to convert spreadsheets.")
        }
        var input = url
        var temp: URL?
        if ext == "tsv" {
            // Numbers reads CSV reliably; TSV goes through a temporary CSV.
            let rows = Delimited.parse(try String(contentsOf: url, encoding: .utf8), separator: "\t")
            let csv = FileManager.default.temporaryDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")
            try Delimited.write(rows, separator: ",").write(to: csv, atomically: true, encoding: .utf8)
            input = csv
            temp = csv
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        if format == .tsv {
            let csv = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            try await IWork.run(.numbers, input: input, output: csv, as: "CSV")
            defer { try? FileManager.default.removeItem(at: csv) }
            let rows = Delimited.parse(try String(contentsOf: csv, encoding: .utf8), separator: ",")
            try Delimited.write(rows, separator: "\t").write(to: output, atomically: true, encoding: .utf8)
            return output
        }
        let exportName: String? = switch format {
        case .xlsx: "Microsoft Excel"
        case .csv: "CSV"
        case .pdf: "PDF"
        default: nil
        }
        try await IWork.run(.numbers, input: input, output: output, as: exportName)
        return output
    }
}

private extension DocumentFormat {
    /// Formats Pages can't export, reached by converting its Word export.
    var needsTextPass: Bool { [.doc, .odt, .html, .md].contains(self) }
}

// MARK: - iWork automation

/// Drives Pages, Keynote and Numbers through AppleScript. The first use asks for permission to control the app.
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    static func isInstalled(_ app: App) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    /// Opens `input` in the app and exports it (`exportName` set) or saves it natively (`exportName` nil).
    static func run(_ app: App, input: URL, output: URL, as exportName: String?, properties: String? = nil) async throws {
        let action: String
        if let exportName {
            let props = properties.map { " with properties \($0)" } ?? ""
            action = "export d to (POSIX file \(quoted(output.path))) as \(exportName)\(props)"
        } else {
            action = "save d in (POSIX file \(quoted(output.path)))"
        }
        let script = """
        tell application id "\(app.bundleID)"
            set d to open (POSIX file \(quoted(input.path)))
            try
                \(action)
            on error message
                close d saving no
                error message
            end try
            close d saving no
        end tell
        """
        do {
            try await launchHidden(app)
            do {
                try await Shell.run("/usr/bin/osascript", ["-e", script])
            } catch where error.localizedDescription.contains("(-600)") {
                // The app was still starting up; give it a moment and try once more.
                try await Task.sleep(for: .seconds(2))
                try await Shell.run("/usr/bin/osascript", ["-e", script])
            }
        } catch {
            let message = error.localizedDescription
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                throw HaluError.failed("Allow Halu Converter to control \(app.rawValue) in System Settings → Privacy & Security → Automation.")
            }
            throw HaluError.failed("\(app.rawValue) couldn't convert “\(input.lastPathComponent)”: \(message)")
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw HaluError.failed("\(app.rawValue) didn't produce a file.")
        }
    }

    /// Starts the app behind other windows and waits until it can take commands.
    /// Not hidden: Pages stalls on documents opened while hidden.
    private static func launchHidden(_ app: App) async throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first, running.isFinishedLaunching {
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<50 where !running.isFinishedLaunching {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(600))
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Text → PDF

enum PDFTextRenderer {
    /// Paginates attributed text onto A4 pages with CoreText.
    static func render(_ text: NSAttributedString, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let frameRect = page.insetBy(dx: 64, dy: 64)
        var mediaBox = page
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw HaluError.writeFailed(url) }

        // CoreText reads its own color key; carry AppKit colors over and default to black on white paper.
        let printable = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: printable.length)
        printable.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: CGColor.black, range: full)
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let isLight = color.brightnessComponent > 0.85
            printable.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                   value: isLight ? CGColor.black : color.cgColor, range: range)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(printable)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < printable.length
        ctx.closePDF()
    }
}

// MARK: - Markdown

enum Markdown {
    /// Small Markdown → HTML converter: headings, lists, quotes, code, bold, italic, links.
    static func html(from markdown: String) -> String {
        var html = ""
        var inCode = false
        var listTag: String?
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"; paragraph = [] }
        }
        func closeList() {
            if let tag = listTag { html += "</\(tag)>\n"; listTag = nil }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph(); closeList()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += escape(rawLine) + "\n"; continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
               (1...6).contains(level), line.dropFirst(level).first == " " {
                flushParagraph(); closeList()
                html += "<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                if listTag != "ul" { closeList(); html += "<ul>\n"; listTag = "ul" }
                html += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                if listTag != "ol" { closeList(); html += "<ol>\n"; listTag = "ol" }
                html += "<li>\(inline(String(line[line.index(dot, offsetBy: 2)...])))</li>\n"
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html += "<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>\n"
            } else if line == "---" || line == "***" {
                flushParagraph(); closeList()
                html += "<hr>\n"
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph(); closeList()
        if inCode { html += "</code></pre>\n" }

        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 12pt; line-height: 1.4; }
        h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
        code, pre { font-family: Menlo, monospace; font-size: 10.5pt; }
        blockquote { color: #555; margin-left: 12pt; }
        </style></head><body>\(html)</body></html>
        """
    }

    /// Attributed text → Markdown, keeping headings (by font size), bold, italic and links.
    static func markdown(from text: NSAttributedString) -> String {
        var result = ""
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else { result += "\n"; return }
            var line = ""
            var maxSize: CGFloat = 0
            text.enumerateAttributes(in: paragraphRange) { attrs, range, _ in
                var run = string.substring(with: range)
                let font = attrs[.font] as? NSFont
                maxSize = max(maxSize, font?.pointSize ?? 12)
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let trimmed = run.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    if traits.contains(.bold) { run = run.replacingOccurrences(of: trimmed, with: "**\(trimmed)**") }
                    if traits.contains(.italic) { run = run.replacingOccurrences(of: trimmed, with: "*\(trimmed)*") }
                    if let link = attrs[.link] { run = "[\(run)](\(link))" }
                }
                line += run
            }
            let prefix = maxSize >= 20 ? "# " : maxSize >= 16 ? "## " : maxSize >= 14 ? "### " : ""
            if !prefix.isEmpty { line = line.replacingOccurrences(of: "**", with: "") }
            // System list markers look like "\t•\tItem" or "\t1.\tItem".
            if let match = line.range(of: #"^\s*[•◦▪‣⁃-]\s+"#, options: .regularExpression) {
                result += "- " + line[match.upperBound...] + "\n"
                return
            }
            if let match = line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) {
                result += line[match].trimmingCharacters(in: .whitespaces) + " " + line[match.upperBound...] + "\n"
                return
            }
            result += prefix + line + "\n\n"
        }
        return result.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"(?<![\w])_([^_]+)_(?![\w])"#, "<i>$1</i>"),
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "$1"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - CSV / TSV

enum Delimited {
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            inQuotes = false
                            if next == separator { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else { inQuotes = false }
                } else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == separator {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func write(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(separator) || field.contains("\n") || (separator == "," && field.contains("\""))
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }
}
