import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            WindowBackground()
            if model.files.isEmpty {
                DropZoneView(isTargeted: isTargeted)
                    .padding(32)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack(spacing: 0) {
                    FileSidebar()
                        .frame(width: 280)
                    Divider()
                    WorkspaceView()
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.files.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted && !model.files.isEmpty {
                DropOverlay()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .onAppear { WindowOpener.action = { openWindow(id: "main") } }
    }
}

struct WindowBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.halu.opacity(0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.pink.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Empty state

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 26) {
            AppBadge(size: 84)
                .scaleEffect(isTargeted ? 1.08 : 1)
                .rotationEffect(.degrees(isTargeted ? -6 : 0))

            VStack(spacing: 8) {
                Text(isTargeted ? "Drop to add" : "Drop files here")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Convert, compress, merge and split. Everything stays on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                KindChip(symbol: "photo", text: "Images")
                KindChip(symbol: "doc.richtext", text: "PDF")
                KindChip(symbol: "film", text: "Video")
                KindChip(symbol: "waveform", text: "Audio")
            }

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Choose Files…", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.halu)
            .controlSize(.large)
            .keyboardShortcut("o")

            WheelHint()
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(isTargeted ? Color.halu.opacity(0.10) : Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(isTargeted ? Color.halu : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [9, 7]))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
    }
}

/// Explains the main feature: the wheel works from anywhere, no window needed.
struct WheelHint: View {
    @AppStorage(TriggerKey.defaultsKey) private var trigger: TriggerKey = .shift

    var body: some View {
        HStack(spacing: 16) {
            MiniWheel()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("You don't need this window")
                    .font(.headline)
                Text("Drag any file and hold **\(trigger.label)**: a flower of actions blooms under the cursor. Drop on a petal and the result lands next to the original. Or right-click a file → **Quick Actions / Services → Convert with Halu**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $trigger) {
                ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(16)
        .frame(maxWidth: 620)
        .background(Color.halu.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.halu.opacity(0.25)))
    }
}

private struct MiniWheel: View {
    var body: some View {
        ZStack {
            ForEach(0..<6) { i in
                AnnularSector(start: Double(i) * 60 + 3, end: Double(i + 1) * 60 - 3, inner: 12, outer: 27)
                    .fill(i == 1 ? AnyShapeStyle(Color.halu) : AnyShapeStyle(Color.primary.opacity(0.15)))
            }
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.halu.opacity(0.08)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.halu, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                .padding(12)
            Label("Add to list", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar

struct FileSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppBadge(size: 28)
                Text("Halu Converter")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 16)

            HStack {
                Text("\(model.files.count) \(model.files.count == 1 ? "file" : "files") · \(model.totalSize.byteString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clear() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Color.halu)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)

            List {
                ForEach(model.files) { file in
                    FileRow(file: file)
                        .listRowSeparator(.hidden)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add Files…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: InputFile
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileThumbnail(url: file.url, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.url.pathExtension.uppercased()) · \(file.size.byteString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.remove(file)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Remove", role: .destructive) { model.remove(file) }
        }
    }
}

// MARK: - Workspace

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should we do?")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                if model.availableTools.isEmpty {
                    ContentUnavailableView(
                        "No actions for this mix",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Actions work on files of one type. Images and PDFs can be combined into one PDF.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    ForEach(ToolCategory.allCases) { category in
                        let tools = model.availableTools.filter { $0.category == category }
                        if !tools.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.rawValue.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.8)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                                    ForEach(tools) { tool in
                                        ToolCard(tool: tool, isSelected: model.selectedTool == tool) {
                                            model.selectedTool = tool
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if let tool = model.selectedTool, tool.accepts(model.files) {
                    OptionsCard(tool: tool)
                        .id(tool)
                }

                if !model.jobs.isEmpty {
                    ActivityList()
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 40)
            .padding(.bottom, 30)
            .animation(.smooth(duration: 0.2), value: model.selectedTool)
        }
    }

    private var summary: String {
        let counts = Dictionary(grouping: model.files, by: \.kind).mapValues(\.count)
        let parts = [FileKind.image, .pdf, .video, .audio].compactMap { kind -> String? in
            guard let n = counts[kind] else { return nil }
            let noun = kind == .pdf ? "PDF" : kind.label
            return "\(n) \(noun)\(n == 1 || kind == .audio ? "" : "s")"
        }
        return parts.joined(separator: ", ") + " selected"
    }
}
