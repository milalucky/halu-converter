import AppKit
import Observation
import SwiftUI

/// Floating glass card at the bottom of the screen with progress and results of wheel actions,
/// so you never need to open the main window.
@MainActor
final class ToastController {
    static let shared = ToastController()

    private let model = ToastModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(_ jobs: [Job], until task: Task<Void, Never>) {
        let current = present { $0.jobs = jobs; $0.message = nil }
        Task {
            await task.value
            let failed = jobs.contains { if case .failed = $0.state { true } else { false } }
            try? await Task.sleep(for: .seconds(failed ? 8 : 5))
            guard self.generation == current else { return }
            self.hide()
        }
    }

    /// A short confirmation without a job, e.g. "Path copied".
    func flash(_ message: String, symbol: String) {
        let current = present { $0.jobs = []; $0.message = (message, symbol) }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard self.generation == current else { return }
            self.hide()
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func present(_ update: (ToastModel) -> Void) -> Int {
        generation += 1
        update(model)
        let panel = panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let frame = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 20))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        return generation
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: ToastView(model: model, onClose: { [weak self] in self?.hide() }))
        return panel
    }
}

@MainActor @Observable
final class ToastModel {
    var jobs: [Job] = []
    var message: (String, String)?
}

private struct ToastView: View {
    let model: ToastModel
    let onClose: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Group {
                if let (text, symbol) = model.message {
                    Label(text, systemImage: symbol)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.jobs.prefix(3)) { job in
                            ToastJobRow(job: job)
                            if job.id != model.jobs.prefix(3).last?.id { Divider().opacity(0.5).padding(.leading, 62) }
                        }
                        if model.jobs.count > 3 {
                            Text("+ \(model.jobs.count - 3) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }
                    }
                    .frame(width: 400)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.halu.opacity(0.5), .haluPink.opacity(0.3), .haluViolet.opacity(0.4)],
                                                 startPoint: .leading, endPoint: .trailing), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .overlay(alignment: .topLeading) {
                if model.message == nil {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.background))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -5, y: -5)
                }
            }
            .padding(14)
        }
        .frame(width: 440, height: 200)
    }
}

private struct ToastJobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                FileThumbnail(url: job.state == .done ? (job.outputs.last ?? job.inputs[0].url) : job.inputs[0].url, size: 28)
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: job.state == .done ? 1 : max(job.progress, 0.04))
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: job.progress)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if job.state == .done, let first = job.outputs.first {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([first]) }
                    .buttonStyle(.borderedProminent)
                    .tint(.halu)
                    .controlSize(.small)
                    .onDrag { NSItemProvider(object: first as NSURL) }
                    .help("Click to show in Finder, or drag the result anywhere")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var title: String {
        job.state == .done ? (job.outputs.first?.lastPathComponent ?? job.title) : job.title
    }

    private var ringStyle: AnyShapeStyle {
        switch job.state {
        case .done: AnyShapeStyle(Color.haluMint)
        case .failed: AnyShapeStyle(Color.orange)
        default: AnyShapeStyle(AngularGradient(colors: [.halu, .haluPink, .haluViolet, .halu], center: .center))
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued:
            Text("\(job.tool.title) · waiting")
        case .running:
            Text("\(job.tool.title) · \(Int(job.progress * 100))%")
        case .done:
            if [.splitPDF, .pdfToImages, .convertPresentation, .extractArchive, .makeSketch].contains(job.tool), job.outputs.count > 1 {
                Text("\(job.outputs.count - 1) files in a new folder")
            } else if job.tool == .makeSketch {
                Text("Sketch saved next to the original")
            } else if job.inputSize > 0 && job.outputSize > 0 {
                let change = Double(job.outputSize - job.inputSize) / Double(job.inputSize) * 100
                Text("\(job.inputSize.byteString) → \(job.outputSize.byteString)  ")
                    + Text(change <= 0 ? "−\(Int(-change.rounded()))%" : "+\(Int(change.rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundColor(change <= 0 ? .haluMint : .secondary)
            } else {
                Text("Saved next to the original")
            }
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        }
    }
}
