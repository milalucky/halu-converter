import AppKit
import ServiceManagement
import SwiftUI

@main
struct HaluApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Halu Converter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Clear Files") { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.files.isEmpty)
            }
        }

        // Keeps the wheel available after the window is closed.
        MenuBarExtra("Halu Converter", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent()
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(TriggerKey.defaultsKey) private var trigger: TriggerKey = .shift
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text("Hold \(trigger.label) while dragging a file")
        Divider()
        Button("Open Halu Converter") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Picker("Wheel Key", selection: $trigger) {
            ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { WindowOpener.action = { openWindow(id: "main") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { DragWatcher.shared.start() }
        #if DEBUG
        // HALU_DEMO_WHEEL="/path/a.png:/path/b.png" opens the wheel at screen center for visual checks.
        if let paths = ProcessInfo.processInfo.environment["HALU_DEMO_WHEEL"], let screen = NSScreen.screens.first {
            let urls = paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            MainActor.assumeIsolated {
                WheelController.shared.show(for: urls, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
                if let hover = ProcessInfo.processInfo.environment["HALU_DEMO_HOVER"].flatMap(Int.init) {
                    WheelController.shared.model.hovered = .action(hover)
                }
            }
        }
        #endif
    }

    /// The app keeps running in the menu bar so the wheel works with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.openMain() } }
        return true
    }
}
