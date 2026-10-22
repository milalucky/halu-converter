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
        guard !urls.isEmpty else { return }
        WheelController.shared.show(for: urls, at: NSEvent.mouseLocation, mode: .drag)
    }
}

// MARK: - Panel

private final class WheelPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WheelController {
    enum Mode { case drag, click }

    static let shared = WheelController()
    static let size: CGFloat = 490

    let model = WheelModel()
    private var panel: WheelPanel?
    private var generation = 0
    private var monitors: [Any] = []

    var isVisible: Bool { panel?.isVisible == true }

    /// `.drag`: drop a dragged file on a petal. `.click`: opened from "Open With" or Services, pick with a click or 1–9.
    func show(for urls: [URL], at point: NSPoint, mode: Mode) {
        hideMonitors()
        generation += 1
        model.load(urls, mode: mode)
        let panel = panel ?? makePanel()
        self.panel = panel

        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let frame = screen.frame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - Self.size)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - Self.size)
        }
        panel.setFrameOrigin(origin)
        panel.allowsKey = mode == .click
        if mode == .click {
            panel.makeKeyAndOrderFront(nil)
            installClickMonitors()
        } else {
            panel.orderFrontRegardless()
        }
        model.isPresented = false
        DispatchQueue.main.async { self.model.isPresented = true }
    }

    func hide() {
        generation += 1
        hideMonitors()
        model.isPresented = false
        model.hovered = nil
        panel?.orderOut(nil)
    }

    /// Mouse went up: a drop on the wheel already handled itself; otherwise close shortly after.
    func mouseReleased() {
        guard isVisible, model.mode == .drag else { return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func perform(_ target: WheelModel.Target) {
        let urls = model.urls
        let actions = model.actions
        hide()
        switch target {
        case .action(let index):
            guard actions.indices.contains(index) else { return }
            AppModel.shared.runQuick(actions[index], urls: urls)
        case .moon(let index):
            FileAction.allCases[index].perform(on: urls)
        case .center:
            AppModel.shared.add(urls)
            WindowOpener.openMain()
        }
    }

    private func installClickMonitors() {
        // Clicks in other apps or in our other windows close the wheel; Esc closes, 1–9 picks a petal.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .leftMouseDown {
                    if event.window !== self.panel { self.hide() }
                    return event
                }
                if event.keyCode == 53 { self.hide(); return nil }
                if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...self.model.actions.count).contains(digit) {
                    self.perform(.action(digit - 1))
                    return nil
                }
                return event
            }
        }) { monitors.append(local) }
    }

    private func hideMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makePanel() -> WheelPanel {
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
        case moon(Int)
        case center
    }

    var urls: [URL] = []
    var files: [InputFile] = []
    var actions: [QuickAction] = []
    var hovered: Target?
    var isPresented = false
    var mode: WheelController.Mode = .drag

    let coreRadius: CGFloat = 52
    let petalBase: CGFloat = 64
    let petalTip: CGFloat = 178
    let moonRadius: CGFloat = 218
    let moonSize: CGFloat = 38

    func load(_ urls: [URL], mode: WheelController.Mode) {
        self.urls = urls
        self.mode = mode
        files = urls.map(InputFile.init)
        actions = QuickAction.actions(for: files)
        hovered = nil
    }

    var petalSpan: Double { 360 / Double(max(actions.count, 1)) }

    /// Petal direction in degrees clockwise from 12 o'clock.
    func angle(of index: Int) -> Double { Double(index) * petalSpan }

    /// Moons sit on the lower arc, between the petal tips.
    func moonAngle(of index: Int) -> Double {
        let count = FileAction.allCases.count
        return 180 + (Double(index) - Double(count - 1) / 2) * 30
    }

    func moonCenter(_ index: Int, size: CGFloat) -> CGPoint {
        point(angle: moonAngle(of: index), radius: moonRadius, size: size)
    }

    func point(angle: Double, radius: CGFloat, size: CGFloat) -> CGPoint {
        let r = CGFloat(angle * .pi / 180)
        return CGPoint(x: size / 2 + radius * sin(r), y: size / 2 - radius * cos(r))
    }

    func target(at point: CGPoint, size: CGFloat) -> Target? {
        for index in FileAction.allCases.indices {
            let c = moonCenter(index, size: size)
            if hypot(point.x - c.x, point.y - c.y) < moonSize / 2 + 6 { return .moon(index) }
        }
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        let distance = hypot(dx, dy)
        if distance < coreRadius + 6 { return .center }
        guard distance <= petalTip + 14, !actions.isEmpty else { return nil }
        // Petals are centered on their angle, so shift by half a span before bucketing.
        let degrees = (atan2(dy, dx) * 180 / .pi + 90 + petalSpan / 2 + 720).truncatingRemainder(dividingBy: 360)
        return .action(min(Int(degrees / petalSpan), actions.count - 1))
    }

    var caption: String {
        switch hovered {
        case .action(let i) where actions.indices.contains(i): actions[i].caption
        case .moon(let i): FileAction.allCases[i].title
        case .center: "Open in app"
        default:
            if actions.isEmpty { "Pick a file action" }
            else if files.count == 1 { files[0].url.lastPathComponent }
            else { "\(files.count) files" }
        }
    }

    /// Sunset spectrum across the petals: amber → coral → pink → violet → indigo.
    func color(of index: Int) -> Color {
        let stops: [(Double, Double, Double)] = [(1.00, 0.62, 0.20), (1.00, 0.42, 0.33), (0.98, 0.33, 0.56), (0.74, 0.36, 0.95), (0.42, 0.44, 1.00)]
        let t = actions.count > 1 ? Double(index) / Double(actions.count - 1) : 0
        let scaled = t * Double(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        let f = scaled - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

// MARK: - View

struct WheelView: View {
    let model: WheelModel
    let size: CGFloat

    var body: some View {
        ZStack {
            // Soft backdrop glow so the flower reads on any wallpaper.
            Circle()
                .fill(RadialGradient(colors: [Color.black.opacity(0.28), .clear], center: .center, startRadius: 40, endRadius: size / 2))
                .opacity(model.isPresented ? 1 : 0)

            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                PetalView(model: model, index: index, action: action, size: size)
            }

            ForEach(Array(FileAction.allCases.enumerated()), id: \.element) { index, action in
                MoonView(model: model, index: index, action: action, size: size)
            }

            CoreView(model: model)
                .scaleEffect(model.isPresented ? 1 : 0.4)
                .opacity(model.isPresented ? 1 : 0)
                .animation(.spring(response: 0.32, dampingFraction: 0.62), value: model.isPresented)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(model: model, size: size))
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard model.mode == .click else { return }
            switch phase {
            case .active(let point): model.hovered = model.target(at: point, size: size)
            case .ended: model.hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            guard model.mode == .click else { return }
            if let target = model.target(at: point, size: size) {
                WheelController.shared.perform(target)
            } else {
                WheelController.shared.hide()
            }
        }
    }
}

private struct PetalView: View {
    let model: WheelModel
    let index: Int
    let action: QuickAction
    let size: CGFloat

    var body: some View {
        let isHovered = model.hovered == .action(index)
        let color = model.color(of: index)
        let angle = model.angle(of: index)
        let width = min(2 * 120 * sin(.pi / Double(max(model.actions.count, 2))) * 0.9, 104)
        let push: CGFloat = isHovered ? 14 : 0
        let bloom: CGFloat = model.isPresented ? 0 : -46
        let labelPoint = model.point(angle: angle, radius: (model.petalBase + model.petalTip) / 2 + 8 + push + bloom, size: size)
        let shape = Petal(angle: angle, base: model.petalBase + push + bloom, tip: model.petalTip + push + bloom, width: CGFloat(width))

        ZStack {
            shape
                .fill(.ultraThinMaterial)
            shape
                .fill(LinearGradient(colors: isHovered ? [color.opacity(0.95), color.mix(with: .white, by: 0.25)]
                                                       : [color.opacity(0.22), color.opacity(0.5)],
                                     startPoint: UnitPoint(x: 0.5 - 0.5 * sin(angle * .pi / 180), y: 0.5 + 0.5 * cos(angle * .pi / 180)),
                                     endPoint: UnitPoint(x: 0.5 + 0.5 * sin(angle * .pi / 180), y: 0.5 - 0.5 * cos(angle * .pi / 180))))
            shape
                .stroke(LinearGradient(colors: [Color.white.opacity(isHovered ? 0.7 : 0.35), color.opacity(0.4)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: isHovered ? 1.5 : 1)

            VStack(spacing: 4) {
                Image(systemName: action.symbol)
                    .font(.system(size: isHovered ? 21 : 18, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary.opacity(0.88))
            .shadow(color: isHovered ? color.opacity(0.8) : .clear, radius: 4)
            .frame(width: CGFloat(width) - 10)
            .position(labelPoint)
        }
        .frame(width: size, height: size)
        .shadow(color: isHovered ? color.opacity(0.75) : .black.opacity(0.18), radius: isHovered ? 18 : 6)
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.68).delay(model.isPresented ? Double(index) * 0.028 : 0), value: model.isPresented)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isHovered)
    }
}

private struct MoonView: View {
    let model: WheelModel
    let index: Int
    let action: FileAction
    let size: CGFloat

    var body: some View {
        let isHovered = model.hovered == .moon(index)
        let center = model.moonCenter(index, size: size)

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .fill(isHovered ? AnyShapeStyle(LinearGradient(colors: [.haluMint, .teal], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.white.opacity(0.06)))
            Circle()
                .strokeBorder(Color.white.opacity(isHovered ? 0.6 : 0.25), lineWidth: 1)
            Image(systemName: action.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHovered ? Color.white : Color.primary.opacity(0.8))
        }
        .frame(width: model.moonSize, height: model.moonSize)
        .scaleEffect(isHovered ? 1.18 : 1)
        .shadow(color: isHovered ? Color.haluMint.opacity(0.7) : .black.opacity(0.2), radius: isHovered ? 12 : 4)
        .position(model.isPresented ? center : CGPoint(x: size / 2, y: size / 2))
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.7).delay(model.isPresented ? 0.12 + Double(index) * 0.04 : 0), value: model.isPresented)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered)
    }
}

private struct CoreView: View {
    let model: WheelModel
    @State private var spin = false

    var body: some View {
        let isHovered = model.hovered == .center
        let diameter = model.coreRadius * 2

        ZStack {
            // Halo: a slowly turning spectrum ring.
            Circle()
                .stroke(AngularGradient(colors: [Color(red: 1, green: 0.62, blue: 0.2), .haluPink, .haluViolet, Color(red: 0.42, green: 0.44, blue: 1),
                                                 Color(red: 1, green: 0.62, blue: 0.2)], center: .center), lineWidth: isHovered ? 5 : 3)
                .blur(radius: isHovered ? 3 : 1.5)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: diameter + 8, height: diameter + 8)
            Circle()
                .fill(.regularMaterial)
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: .init(x: 0.35, y: 0.25), startRadius: 0, endRadius: diameter))
                .frame(width: diameter, height: diameter)

            VStack(spacing: 3) {
                if let first = model.files.first {
                    ZStack(alignment: .topTrailing) {
                        FileThumbnail(url: first.url, size: 34)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        if model.files.count > 1 {
                            Text("\(model.files.count)")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.haluPink))
                                .offset(x: 7, y: -5)
                        }
                    }
                }
                Text(model.caption)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(width: diameter - 14)
            }
        }
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHovered)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
        }
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
                if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
        }
    }
}

// MARK: - Shapes

/// A daisy petal pointing outward from the center: narrow, rounded base and a wide round tip.
/// `angle` in degrees clockwise from 12 o'clock, radii from the shape's center.
struct Petal: Shape {
    var angle: Double
    var base: CGFloat
    var tip: CGFloat
    var width: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(base, tip) }
        set { base = newValue.first; tip = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let length = tip - base
        guard length > 0, width > 0, angle.isFinite else { return Path() }
        let half = width / 2
        let baseHalf = width * 0.2
        let tipRadius = min(half, length / 2)

        // Drawn pointing up from the origin, then rotated into place.
        var path = Path()
        path.move(to: CGPoint(x: -baseHalf, y: 0))
        path.addCurve(to: CGPoint(x: -half, y: -length + tipRadius),
                      control1: CGPoint(x: -half * 0.55, y: -length * 0.15),
                      control2: CGPoint(x: -half, y: -length * 0.45))
        path.addArc(center: CGPoint(x: 0, y: -length + tipRadius), radius: half,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: CGPoint(x: baseHalf, y: 0),
                      control1: CGPoint(x: half, y: -length * 0.45),
                      control2: CGPoint(x: half * 0.55, y: -length * 0.15))
        path.addArc(center: .zero, radius: baseHalf, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()

        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: CGFloat(angle * .pi / 180))
            .translatedBy(x: 0, y: -base)
        return path.applying(transform)
    }
}

/// A ring segment; angles in degrees clockwise from 12 o'clock.
struct AnnularSector: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        guard start.isFinite, end.isFinite, end > start else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            let r = CGFloat(degrees * .pi / 180)
            return CGPoint(x: center.x + radius * sin(r), y: center.y - radius * cos(r))
        }
        let steps = max(Int((end - start) / 3), 2)
        var path = Path()
        path.move(to: point(start, outer))
        for i in 1...steps { path.addLine(to: point(start + (end - start) * Double(i) / Double(steps), outer)) }
        for i in stride(from: steps, through: 0, by: -1) { path.addLine(to: point(start + (end - start) * Double(i) / Double(steps), inner)) }
        path.closeSubpath()
        return path
    }
}
