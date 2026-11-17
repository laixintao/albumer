import SwiftUI
import AppKit

@main
struct AlbumerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(demo: ProcessInfo.processInfo.arguments.contains("--demo"))
    var body: some Scene {
        Window("Albumer", id: "main") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in model.setForeground(false) }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in model.setForeground(true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button(model.playback?.isPlaying == true ? "暂停" : "播放") { Task { await model.togglePlayback() } }
                    .disabled(!model.isConnected || model.isBusy)
                Button("上一首") { Task { await model.perform(.previous) } }.keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.hasPlayback || model.isBusy || model.playback?.allows("skipping_prev") == false)
                Button("下一首") { Task { await model.perform(.next) } }.keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.hasPlayback || model.isBusy || model.playback?.allows("skipping_next") == false)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索专辑") { model.selectedAlbum = nil; model.isSearching = true; model.searchChanged() }
                    .keyboardShortcut("f", modifiers: .command).disabled(!model.isConnected)
            }
            CommandMenu("导航") {
                Button("同步收藏") { Task { await model.refreshCollection() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isConnected || model.isSearching || model.isLoading)
                Button("返回专辑") {
                    if model.selectedAlbum != nil { model.selectedAlbum = nil }
                    else { model.showCollection() }
                }.keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.showSettings || model.showDevices || (model.selectedAlbum == nil && !model.isSearching))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Albumer" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct WindowReader: NSViewRepresentable {
    var model: AppModel
    func makeNSView(context: Context) -> WindowHook { let view = WindowHook(); view.model = model; return view }
    func updateNSView(_ nsView: WindowHook, context: Context) { nsView.model = model }
    static func dismantleNSView(_ nsView: WindowHook, coordinator: ()) { nsView.stopMonitoring() }
    final class WindowHook: NSView {
        weak var model: AppModel?
        private var keyMonitor: Any?
        private var configured = false
        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            // SwiftUI's onExitCommand is not delivered from every AppKit first responder.
            // Monitor only this window; text fields retain normal spaces and editing keys.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, let model = self.model,
                      !model.showSettings, !model.showDevices,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if event.keyCode == 53 && (model.selectedAlbum != nil || model.isSearching) {
                    if model.selectedAlbum != nil { model.selectedAlbum = nil }
                    else { model.showCollection() }
                    return nil
                }
                if event.keyCode == 49, model.isConnected, !model.isSearching, !(self.window?.firstResponder is NSTextView) {
                    Task { await model.togglePlayback() }
                    return nil
                }
                return event
            }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Color.room)
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            if !configured {
                configured = true
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") }) {
                    let components = argument.dropFirst("--window-size=".count).split(separator: "x").compactMap { Double($0) }
                    if components.count == 2 {
                        DispatchQueue.main.async {
                            window.setContentSize(NSSize(width: max(820, components[0]), height: max(640, components[1])))
                        }
                    }
                }
            }
        }
    }
}
