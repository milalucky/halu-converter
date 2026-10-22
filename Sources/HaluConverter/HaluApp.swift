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
        // Lives in the background: the window opens only from the menu bar icon or the wheel's center.
        .defaultLaunchBehavior(.suppressed)
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
    private static let didSetUpKey = "didSetUpLoginItem"

    /// "Open With → Halu Converter" or a drop on the app icon: open the wheel under the cursor.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { WheelController.shared.show(for: urls, at: NSEvent.mouseLocation, mode: .click) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        MainActor.assumeIsolated { DragWatcher.shared.start() }

        // First launch: start with the Mac, so the wheel is always there.
        if !UserDefaults.standard.bool(forKey: Self.didSetUpKey) {
            UserDefaults.standard.set(true, forKey: Self.didSetUpKey)
            try? SMAppService.mainApp.register()
        }

        #if DEBUG
        // HALU_DEMO_WHEEL="/path/a.png:/path/b.png" opens the wheel at screen center for visual checks;
        // HALU_DEMO_HOVER="a2" / "m0" / "c" highlights petal 2, moon 0 or the core.
        if let paths = ProcessInfo.processInfo.environment["HALU_DEMO_WHEEL"], let screen = NSScreen.screens.first {
            let urls = paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            MainActor.assumeIsolated {
                WheelController.shared.show(for: urls, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), mode: .drag)
                if let hover = ProcessInfo.processInfo.environment["HALU_DEMO_HOVER"] {
                    let index = Int(hover.dropFirst()) ?? 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        WheelController.shared.model.hovered = hover.hasPrefix("m") ? .moon(index) : hover == "c" ? .center : .action(index)
                    }
                }
            }
        }
        #endif
    }

    /// Finder → right-click → Services (Quick Actions) → "Convert with Halu".
    @objc func openWheel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated { WheelController.shared.show(for: urls, at: NSEvent.mouseLocation, mode: .click) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { IWorkLifecycle.shared.quitAllNow() }
    }

    /// The app keeps running in the menu bar so the wheel works with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Launching the app again (Finder, Spotlight) opens the full window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.openMain() } }
        return true
    }
}
