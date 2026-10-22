import SwiftUI

struct OptionsCard: View {
    @Environment(AppModel.self) private var model
    let tool: Tool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .foregroundStyle(tool.tint)
                Text(tool.title)
                    .font(.title3.weight(.semibold))
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 14) {
                options(settings: $model.settings)
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    OutputPicker()
                }
            }

            HStack {
                Spacer()
                Button {
                    model.run()
                } label: {
                    HStack(spacing: 8) {
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(runTitle)
                    }
                    .frame(minWidth: 140)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(.halu)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isRunning)
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background.opacity(0.7))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var runTitle: String {
        if model.isRunning { return "Working…" }
        let n = model.files.count
        switch tool {
        case .mergePDF: return "Combine \(n) \(n == 1 ? "file" : "files")"
        default: return n == 1 ? tool.title : "\(tool.title) ×\(n)"
        }
    }

    @ViewBuilder
    private func options(settings s: Binding<ToolSettings>) -> some View {
        switch tool {
        case .convertImage:
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("", selection: s.imageFormat) {
                    ForEach(ImageFormat.writable) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if s.wrappedValue.imageFormat.isLossy {
                qualityRow(s)
            }
            resizeRow(s)

        case .compressImage:
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("", selection: s.compressFormat) {
                    ForEach(CompressImageFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            qualityRow(s)
            resizeRow(s)
            hint("PNG files stay lossless with “Keep format”. Pick JPEG or HEIC for much smaller files.")

        case .mergePDF:
            hint("Files are combined in the order shown in the sidebar. Drag them there to reorder.")

        case .splitPDF:
            GridRow {
                Text("Split").foregroundStyle(.secondary)
                Picker("", selection: s.splitMode) {
                    ForEach(SplitMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            if s.wrappedValue.splitMode == .ranges {
                GridRow {
                    Text("Pages").foregroundStyle(.secondary)
                    TextField("e.g. 1-3, 5, 8-", text: s.splitRanges)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
                hint("Each range becomes its own PDF.")
            }

        case .compressPDF:
            GridRow {
                Text("Level").foregroundStyle(.secondary)
                Picker("", selection: s.pdfCompression) {
                    ForEach(PDFCompressionLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
            }
            hint(s.wrappedValue.pdfCompression.detail)

        case .pdfToImages:
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("", selection: s.pdfImageFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                    Text("HEIC").tag(ImageFormat.heic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            sliderRow("Resolution", value: s.pdfDPI, range: 72...300, step: 6, label: "\(Int(s.wrappedValue.pdfDPI)) dpi")

        case .compressVideo:
            GridRow {
                Text("Quality").foregroundStyle(.secondary)
                Picker("", selection: s.videoPreset) {
                    ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            hint(s.wrappedValue.videoPreset.detail + ". Videos are never upscaled.")

        case .convertVideo:
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("", selection: s.videoContainer) {
                    ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            hint("Copies the streams without re-encoding when possible, so it's fast and lossless.")

        case .videoToGIF:
            sliderRow("Frame rate", value: s.gifFPS, range: 5...30, step: 1, label: "\(Int(s.wrappedValue.gifFPS)) fps")
            sliderRow("Width", value: s.gifWidth, range: 160...1080, step: 20, label: "\(Int(s.wrappedValue.gifWidth)) px")
            hint("GIFs get large quickly. Short clips at 10–15 fps and up to 480 px work best.")

        case .extractAudio:
            hint("Saves the audio track as AAC in an .m4a file.")

        case .convertAudio:
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("", selection: s.audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            hint(audioHint(s.wrappedValue.audioFormat))

        case .convertDocument:
            formatRow(selection: s.documentFormat, cases: DocumentFormat.allCases, label: \.label)
            hint("Pages files and Word-to-PDF go through Pages for the best layout. Everything else converts instantly.")

        case .convertPresentation:
            formatRow(selection: s.slidesFormat, cases: SlidesFormat.allCases, label: \.label)
            hint("Uses Keynote in the background. Slide images are saved into a folder.")

        case .convertSpreadsheet:
            formatRow(selection: s.sheetFormat, cases: SheetFormat.allCases, label: \.label)
            hint("CSV ⇄ TSV converts instantly. Excel, Numbers and PDF go through Numbers.")

        case .makeArchive:
            formatRow(selection: s.archiveFormat, cases: ArchiveFormat.allCases, label: \.label)
            hint(model.files.count > 1 ? "All files go into one archive." : "Folders are packed with everything inside.")

        case .extractArchive:
            hint("Each archive is extracted into its own folder next to it.")

        case .convertSubtitle:
            formatRow(selection: s.subtitleFormat, cases: SubtitleFormat.allCases, label: \.label)
            hint("TXT keeps only the spoken lines, without timings.")
        }
    }

    private func audioHint(_ format: AudioFormat) -> String {
        switch format {
        case .m4a: "AAC, small and widely supported."
        case .flac, .alac: "Lossless: same sound as the original, about half the size of WAV."
        default: "Uncompressed 16-bit PCM."
        }
    }

    private func formatRow<T: Hashable & Identifiable>(selection: Binding<T>, cases: [T], label: KeyPath<T, String>) -> some View {
        GridRow {
            Text("Format").foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(cases) { Text($0[keyPath: label]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func qualityRow(_ s: Binding<ToolSettings>) -> some View {
        sliderRow("Quality", value: s.quality, range: 0.1...1, step: 0.05, label: "\(Int(s.wrappedValue.quality * 100))%")
    }

    @ViewBuilder
    private func resizeRow(_ s: Binding<ToolSettings>) -> some View {
        GridRow {
            Text("Resize").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Toggle("Limit longest side", isOn: s.resizeEnabled)
                if s.wrappedValue.resizeEnabled {
                    Picker("", selection: s.maxDimension) {
                        ForEach([640.0, 1024, 1280, 1600, 2048, 3000, 4096], id: \.self) { Text("\(Int($0)) px").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                    .frame(maxWidth: 320)
                Text(label)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct OutputPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Next to originals") { model.outputFolder = nil }
            Button("Choose Folder…") { model.chooseOutputFolder() }
        } label: {
            Label(model.outputFolder?.lastPathComponent ?? "Next to originals",
                  systemImage: model.outputFolder == nil ? "arrow.turn.down.right" : "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
