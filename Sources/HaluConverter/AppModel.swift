import AppKit
import Observation

@MainActor @Observable
final class Job: Identifiable {
    enum State: Equatable {
        case queued, running, done
        case failed(String)
    }

    let id = UUID()
    let tool: Tool
    let inputs: [InputFile]
    var state: State = .queued
    var progress: Double = 0
    var outputs: [URL] = []
    var outputSize: Int64 = 0

    init(tool: Tool, inputs: [InputFile]) {
        self.tool = tool
        self.inputs = inputs
    }

    var title: String { inputs.count == 1 ? inputs[0].url.lastPathComponent : "\(inputs.count) files" }
    var inputSize: Int64 { inputs.reduce(0) { $0 + $1.size } }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var files: [InputFile] = [] { didSet { reconcileSelection() } }
    var selectedTool: Tool?
    var settings = ToolSettings()
    var jobs: [Job] = []
    var isRunning = false
    /// nil means "save next to the originals".
    var outputFolder: URL?

    var availableTools: [Tool] { Tool.allCases.filter { $0.accepts(files) } }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func add(_ urls: [URL]) {
        let existing = Set(files.map(\.url))
        let expanded = urls.flatMap(Self.expand).filter { !existing.contains($0) }
        let new = expanded.map(InputFile.init).filter { $0.kind != .other }
        files.append(contentsOf: new)
    }

    func remove(_ file: InputFile) { files.removeAll { $0.id == file.id } }
    func clear() { files.removeAll() }

    func move(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    func run() {
        guard let tool = selectedTool, tool.accepts(files), !isRunning else { return }
        isRunning = true
        let (_, task) = enqueue(tool, inputs: files, settings: settings, outputDir: outputFolder)
        Task {
            await task.value
            isRunning = false
        }
    }

    /// Runs a wheel action on dragged files with fixed settings, saving next to the originals.
    func runQuick(_ action: QuickAction, urls: [URL]) {
        let inputs = urls.map(InputFile.init)
        guard action.tool.accepts(inputs) else { return }
        var settings = ToolSettings()
        action.configure(&settings)
        let (newJobs, task) = enqueue(action.tool, inputs: inputs, settings: settings, outputDir: nil)
        ToastController.shared.show(newJobs, until: task)
    }

    @discardableResult
    func enqueue(_ tool: Tool, inputs: [InputFile], settings: ToolSettings, outputDir: URL?) -> ([Job], Task<Void, Never>) {
        let groups = tool.isBatch ? [inputs] : inputs.map { [$0] }
        let newJobs = groups.map { Job(tool: tool, inputs: $0) }
        jobs.insert(contentsOf: newJobs, at: 0)

        let task = Task {
            for job in newJobs {
                job.state = .running
                do {
                    let outputs = try await Processor.run(tool, inputs: job.inputs.map(\.url), settings: settings, outputDir: outputDir) { value in
                        Task { @MainActor in job.progress = value }
                    }
                    job.outputs = outputs
                    job.outputSize = Self.size(of: outputs)
                    job.progress = 1
                    job.state = .done
                } catch {
                    job.state = .failed(error.localizedDescription)
                }
            }
        }
        return (newJobs, task)
    }

    func clearFinishedJobs() { jobs.removeAll { $0.state != .running && $0.state != .queued } }

    private func reconcileSelection() {
        if let selectedTool, selectedTool.accepts(files) { return }
        selectedTool = availableTools.first
    }

    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Size of produced files; folders (from split / export pages) are skipped since their contents are listed too.
    private static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            return values?.isDirectory == true ? total : total + Int64(values?.fileSize ?? 0)
        }
    }
}

enum Processor {
    static func run(_ tool: Tool, inputs: [URL], settings s: ToolSettings, outputDir: URL?,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let url = inputs[0]
        let maxDimension = s.resizeEnabled ? Int(s.maxDimension) : nil
        switch tool {
        case .convertImage:
            return [try ImageEngine.convert(url, to: s.imageFormat, quality: s.quality, maxDimension: maxDimension, outputDir: outputDir)]
        case .compressImage:
            return [try ImageEngine.compress(url, format: s.compressFormat, quality: s.quality, maxDimension: maxDimension, outputDir: outputDir)]
        case .mergePDF:
            return [try PDFEngine.merge(inputs, outputDir: outputDir, progress: progress)]
        case .splitPDF:
            return try PDFEngine.split(url, mode: s.splitMode, ranges: s.splitRanges, outputDir: outputDir, progress: progress)
        case .compressPDF:
            return [try PDFEngine.compress(url, level: s.pdfCompression, outputDir: outputDir, progress: progress)]
        case .pdfToImages:
            return try PDFEngine.toImages(url, format: s.pdfImageFormat, dpi: s.pdfDPI, outputDir: outputDir, progress: progress)
        case .compressVideo:
            return [try await MediaEngine.compressVideo(url, preset: s.videoPreset, outputDir: outputDir, progress: progress)]
        case .convertVideo:
            return [try await MediaEngine.convertVideo(url, to: s.videoContainer, outputDir: outputDir, progress: progress)]
        case .videoToGIF:
            return [try await MediaEngine.makeGIF(url, fps: s.gifFPS, width: s.gifWidth, outputDir: outputDir, progress: progress)]
        case .extractAudio:
            return [try await MediaEngine.extractAudio(url, outputDir: outputDir, progress: progress)]
        case .convertAudio:
            return [try await MediaEngine.convertAudio(url, to: s.audioFormat, outputDir: outputDir, progress: progress)]
        case .convertDocument:
            return [try await DocumentEngine.convert(url, to: s.documentFormat, outputDir: outputDir)]
        case .convertPresentation:
            return try await DocumentEngine.convertSlides(url, to: s.slidesFormat, outputDir: outputDir)
        case .convertSpreadsheet:
            return [try await DocumentEngine.convertSheet(url, to: s.sheetFormat, outputDir: outputDir)]
        case .makeArchive:
            return [try await ArchiveEngine.make(inputs, format: s.archiveFormat, outputDir: outputDir)]
        case .extractArchive:
            return try await ArchiveEngine.extract(url, outputDir: outputDir)
        case .convertSubtitle:
            return [try SubtitleEngine.convert(url, to: s.subtitleFormat, outputDir: outputDir)]
        case .makeSketch:
            return try SketchEngine.toDXF(url, settings: s, outputDir: outputDir)
        }
    }
}
