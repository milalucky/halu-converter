import QuickLookThumbnailing
import SwiftUI

extension Color {
    static let halu = Color(red: 0.98, green: 0.47, blue: 0.20)
    static let haluMint = Color(red: 0.20, green: 0.78, blue: 0.62)
    static let haluViolet = Color(red: 0.55, green: 0.42, blue: 0.98)
    static let haluPink = Color(red: 1.0, green: 0.36, blue: 0.52)
}

struct AppBadge: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.24), Color(red: 0.96, green: 0.33, blue: 0.24)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.halu.opacity(0.35), radius: size * 0.15, y: size * 0.06)
    }
}

struct KindChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct ToolCard: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : tool.tint)
                    .frame(width: 38, height: 38)
                    .background(isSelected ? AnyShapeStyle(tool.tint.gradient) : AnyShapeStyle(tool.tint.opacity(0.14)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(tool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tool.tint.opacity(0.10) : Color.primary.opacity(hovering ? 0.06 : 0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tool.tint.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering && !isSelected ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct FileThumbnail: View {
    let url: URL
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}

// MARK: - Activity

struct ActivityList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVITY")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                Button("Clear") { model.clearFinishedJobs() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(model.isRunning)
            }
            VStack(spacing: 0) {
                ForEach(model.jobs) { job in
                    JobRow(job: job)
                    if job.id != model.jobs.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if job.state == .done, let first = job.outputs.first {
                Image(systemName: "hand.draw")
                    .foregroundStyle(.tertiary)
                    .help("Drag the result to another app")
                    .onDrag { NSItemProvider(object: first as NSURL) }
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(Array(job.outputs.prefix(1))) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView(value: job.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued:
            Text("\(job.tool.title) · waiting")
        case .running:
            Text("\(job.tool.title) · \(Int(job.progress * 100))%")
        case .done:
            HStack(spacing: 4) {
                Text(job.tool.title + " ·")
                if job.tool == .splitPDF || job.tool == .pdfToImages || (job.tool == .makeSketch && job.outputs.count > 1) {
                    Text("\(job.outputs.count - 1) files")
                } else if job.tool == .makeSketch {
                    Text(job.outputSize.byteString)
                } else {
                    Text("\(job.inputSize.byteString) → \(job.outputSize.byteString)")
                    if job.inputSize > 0 {
                        let change = Double(job.outputSize - job.inputSize) / Double(job.inputSize) * 100
                        Text(change <= 0 ? "−\(Int(-change.rounded()))%" : "+\(Int(change.rounded()))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(change <= 0 ? Color.green : Color.orange)
                    }
                }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.orange).lineLimit(2)
        }
    }
}
