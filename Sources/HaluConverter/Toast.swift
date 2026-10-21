import AppKit
import Observation
import SwiftUI

/// Small floating card at the bottom of the screen that shows progress and results of wheel actions,
/// so you never need to open the main window.
@MainActor
final class ToastController {
    static let shared = ToastController()

    private let model = ToastModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(_ jobs: [Job], until task: Task<Void, Never>) {
        generation += 1
        let current = generation
        model.jobs = jobs
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        Task {
            await task.value
            let failed = jobs.contains { if case .failed = $0.state { true } else { false } }
            try? await Task.sleep(for: .seconds(failed ? 8 : 5))
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

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
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
}

private struct ToastView: View {
    let model: ToastModel
    let onClose: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ForEach(model.jobs.prefix(3)) { job in
                    JobRow(job: job)
                }
                if model.jobs.count > 3 {
                    Text("+ \(model.jobs.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .overlay(alignment: .topLeading) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.background))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(14)
        }
        .frame(width: 420, height: 180)
    }
}
