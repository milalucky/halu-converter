import AppKit
import Observation
import SwiftUI

// MARK: - Drag detection

/// Notices a file drag anywhere in macOS (Finder, Desktop, other apps) while the trigger key is held,
/// and opens the wheel under the cursor. Polls the shared drag pasteboard, so it needs no special permissions.
@MainActor
final class DragWatcher {
    static let shared = DragWatcher()

    private let pasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseDownMonitor: Any?
    private var mouseWasDown = false
    private var changeCountAtMouseDown = 0

    func start() {
        guard timer == nil else { return }
        changeCountAtMouseDown = pasteboard.changeCount
        // The global monitor catches the exact moment of mouse-down in other apps; the timer is the fallback.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.markMouseDown() }
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func markMouseDown() {
        changeCountAtMouseDown = pasteboard.changeCount
        mouseWasDown = true
    }

    private func tick() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0
        if isDown && !mouseWasDown { changeCountAtMouseDown = pasteboard.changeCount }
        if !isDown && mouseWasDown { WheelController.shared.mouseReleased() }
        mouseWasDown = isDown

        guard isDown, !WheelController.shared.isVisible,
              NSEvent.modifierFlags.contains(TriggerKey.current.flags),
              pasteboard.changeCount != changeCountAtMouseDown
        else { return }

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // Files with no quick actions (unknown types) don't get a wheel at all.
        guard !urls.isEmpty, !QuickAction.actions(for: urls.map(InputFile.init)).isEmpty else { return }
        WheelController.shared.show(for: urls, at: NSEvent.mouseLocation)
    }
}

// MARK: - Panel

private final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WheelController {
    static let shared = WheelController()
    static let size: CGFloat = 400

    let model = WheelModel()
    private var panel: NSPanel?
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true }

    func show(for urls: [URL], at point: NSPoint) {
        generation += 1
        model.load(urls)
        let panel = panel ?? makePanel()
        self.panel = panel

        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let frame = screen.frame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - Self.size)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - Self.size)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { model.isPresented = true }
    }

    func hide() {
        generation += 1
        model.isPresented = false
        model.hovered = nil
        panel?.orderOut(nil)
    }

    /// Mouse went up: a drop on the wheel already handled itself; otherwise close shortly after.
    func mouseReleased() {
        guard isVisible else { return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func perform(_ target: WheelModel.Target) {
        let urls = model.urls
        hide()
        switch target {
        case .action(let index):
            guard model.actions.indices.contains(index) else { return }
            AppModel.shared.runQuick(model.actions[index], urls: urls)
        case .center:
            AppModel.shared.add(urls)
            WindowOpener.openMain()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WheelView(model: model, size: Self.size))
        return panel
    }
}

/// Lets AppKit code (the wheel, the menu bar) bring the SwiftUI main window back after it was closed.
@MainActor
enum WindowOpener {
    static var action: (() -> Void)?

    static func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            action?()
        }
    }
}

// MARK: - Model

@MainActor @Observable
final class WheelModel {
    enum Target: Equatable {
        case action(Int)
        case center
    }

    var urls: [URL] = []
    var files: [InputFile] = []
    var actions: [QuickAction] = []
    var hovered: Target?
    var isPresented = false

    let innerRadius: CGFloat = 66
    let outerRadius: CGFloat = 176

    func load(_ urls: [URL]) {
        self.urls = urls
        files = urls.map(InputFile.init)
        actions = QuickAction.actions(for: files)
        hovered = nil
    }

    /// Angle of a slice's start, in degrees clockwise from 12 o'clock.
    func startAngle(of index: Int) -> Double { Double(index) * 360 / Double(max(actions.count, 1)) }

    func target(at point: CGPoint, size: CGFloat) -> Target? {
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        let distance = hypot(dx, dy)
        if distance < innerRadius { return .center }
        guard distance <= outerRadius + 24, !actions.isEmpty else { return nil }
        let degrees = (atan2(dy, dx) * 180 / .pi + 90 + 360).truncatingRemainder(dividingBy: 360)
        return .action(min(Int(degrees / (360 / Double(actions.count))), actions.count - 1))
    }

    var caption: String {
        switch hovered {
        case .action(let i) where actions.indices.contains(i): actions[i].caption
        case .center: "Open in app"
        default: actions.isEmpty ? "No quick actions" : "Drop on an action"
        }
    }
}

// MARK: - View

struct WheelView: View {
    let model: WheelModel
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: model.outerRadius * 2 + 12, height: model.outerRadius * 2 + 12)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)

            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                WheelSlice(model: model, index: index, action: action, size: size)
            }

            WheelCenter(model: model)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .scaleEffect(model.isPresented ? 1 : 0.6)
        .opacity(model.isPresented ? 1 : 0)
        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(model: model, size: size))
    }
}

private struct WheelSlice: View {
    let model: WheelModel
    let index: Int
    let action: QuickAction
    let size: CGFloat

    var body: some View {
        let isHovered = model.hovered == .action(index)
        let span = 360 / Double(max(model.actions.count, 1))
        let start = model.startAngle(of: index)
        let mid = CGFloat((start + span / 2) * .pi / 180)
        let labelRadius = (model.innerRadius + model.outerRadius) / 2

        ZStack {
            AnnularSector(start: start + 1, end: start + span - 1, inner: model.innerRadius + 4, outer: model.outerRadius)
                .fill(isHovered ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.24), Color.halu],
                                                               startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.primary.opacity(0.06)))
            AnnularSector(start: start + 1, end: start + span - 1, inner: model.innerRadius + 4, outer: model.outerRadius)
                .stroke(Color.primary.opacity(isHovered ? 0 : 0.08), lineWidth: 1)

            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 20, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .offset(x: labelRadius * sin(mid), y: -labelRadius * cos(mid))
        }
        .frame(width: size, height: size)
        .scaleEffect(isHovered ? 1.05 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
    }
}

private struct WheelCenter: View {
    let model: WheelModel

    var body: some View {
        let isHovered = model.hovered == .center
        VStack(spacing: 4) {
            if let first = model.files.first {
                ZStack(alignment: .topTrailing) {
                    FileThumbnail(url: first.url, size: 38)
                    if model.files.count > 1 {
                        Text("\(model.files.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.halu, in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
            }
            Text(model.caption)
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: model.innerRadius * 1.6)
        }
        .frame(width: model.innerRadius * 2, height: model.innerRadius * 2)
        .background(Circle().fill(isHovered ? Color.halu.opacity(0.25) : Color.primary.opacity(0.04)))
        .overlay(Circle().strokeBorder(isHovered ? Color.halu : Color.primary.opacity(0.08), lineWidth: isHovered ? 2 : 1))
    }
}

private struct WheelDropDelegate: DropDelegate {
    let model: WheelModel
    let size: CGFloat

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: model.hovered == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { model.hovered = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let target = model.target(at: info.location, size: size) else { return false }
            WheelController.shared.perform(target)
            return true
        }
    }

    private func update(_ info: DropInfo) {
        MainActor.assumeIsolated {
            let target = model.target(at: info.location, size: size)
            if target != model.hovered {
                model.hovered = target
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }
}

/// A ring segment; angles in degrees clockwise from 12 o'clock.
struct AnnularSector: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            let r = CGFloat(degrees * .pi / 180)
            return CGPoint(x: center.x + radius * sin(r), y: center.y - radius * cos(r))
        }
        guard start.isFinite, end.isFinite, end > start else { return Path() }
        let steps = max(Int((end - start) / 3), 2)
        var path = Path()
        path.move(to: point(start, outer))
        for i in 1...steps { path.addLine(to: point(start + (end - start) * Double(i) / Double(steps), outer)) }
        for i in stride(from: steps, through: 0, by: -1) { path.addLine(to: point(start + (end - start) * Double(i) / Double(steps), inner)) }
        path.closeSubpath()
        return path
    }
}
