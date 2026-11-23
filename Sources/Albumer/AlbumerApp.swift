import SwiftUI
import AppKit

@main
struct AlbumerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(demo: ProcessInfo.processInfo.arguments.contains("--demo"))
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library
    private var playbackMatchesSelection: Bool {
        model.hasPlayback && (model.selectedAlbum == nil || model.playback?.context?.uri == model.selectedAlbum?.albumID.uri)
    }
    var body: some Scene {
        Window("Albumer", id: "main") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in model.setForeground(false) }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in model.setForeground(true) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1120, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button(playbackMatchesSelection && model.playback?.isPlaying == true ? "暂停" : "播放") { Task { await model.togglePlayback() } }
                    .disabled(!model.isConnected || model.isBusy)
                Button("上一首") { Task { await model.perform(.previous) } }.keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!playbackMatchesSelection || model.isBusy || model.playback?.allows("skipping_prev") == false)
                Button("下一首") { Task { await model.perform(.next) } }.keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!playbackMatchesSelection || model.isBusy || model.playback?.allows("skipping_next") == false)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索专辑") { model.resetNavigation(); model.isSearching = true; model.searchChanged() }
                    .keyboardShortcut("f", modifiers: .command).disabled(!model.isConnected)
            }
            CommandMenu("导航") {
                Button("专辑收藏") { model.showCollection() }
                    .keyboardShortcut("1", modifiers: .command).disabled(!model.isConnected)
                Button("同步收藏") { Task { await model.refreshCollection() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isConnected || model.isSearching || model.isLoading)
                Button(model.backLabel) { model.requestBack() }.keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.showSettings || !model.canGoBack)
                if let album = model.selectedAlbum {
                    Divider()
                    Button(model.savedIDs.contains(album.id) ? "移除收藏" : "收藏专辑") {
                        Task { await model.toggleSaved(album) }
                    }.disabled(model.isSaving || !model.checkedSavedIDs.contains(album.id))
                }
                if model.isDemo {
                    Divider()
                    Button("退出预览") { Task { await model.exitDemo() } }
                }
            }
            CommandMenu("显示") {
                Toggle("按艺人分组", isOn: $groupByArtist)
                Picker("专辑排序", selection: $sortOrder) {
                    ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
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
        if !flag { sender.windows.first(where: { $0.canBecomeMain && $0.level == .normal })?.makeKeyAndOrderFront(nil) }
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
                      !model.showSettings,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                if event.keyCode == 53 && model.canGoBack {
                    model.requestBack()
                    return nil
                }
                if event.keyCode == 49, model.isConnected, !model.isSearching, !(self.window?.firstResponder is NSTextView) {
                    Task { await model.togglePlayback() }
                    return nil
                }
                return event
            }
            window.backgroundColor = .windowBackgroundColor
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
