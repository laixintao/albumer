import SwiftUI
import AppKit

@main
struct AlbumerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let announcements = TrackAnnouncementController(
            present: { TrackToastPanel.shared.present($0) },
            dismiss: { TrackToastPanel.shared.dismiss() }
        )
        _model = State(initialValue: AppModel(demo: ProcessInfo.processInfo.arguments.contains("--demo"),
                                             trackAnnouncements: announcements))
    }
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library
    private var playbackMatchesSelection: Bool {
        model.hasPlayback && (model.selectedAlbum == nil || model.playingAlbumID == model.selectedAlbum?.albumID)
    }
    var body: some Scene {
        WindowGroup("Albumer", id: "main") {
            MainWindowContent(model: model, delegate: delegate)
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

private struct MainWindowContent: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .onAppear {
                delegate.bind(model, openMainWindow: { openWindow(id: "main") })
                model.setForeground(true)
            }
            .onDisappear { model.setForeground(false) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var openMainWindow: (@MainActor () -> Void)?
    private var openingWindow = false

    func bind(_ model: AppModel, openMainWindow: @escaping @MainActor () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        openingWindow = false
        TrackToastPanel.shared.onActivate = { [weak self] announcement in
            guard let self, let model = self.model else { return }
            self.showMainWindow()
            Task { await model.openAlbum(from: announcement) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(spotifyPlaybackChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private nonisolated func spotifyPlaybackChanged(_ notification: Notification) {
        let uri = notification.userInfo?["Track ID"] as? String
        let id = uri.flatMap { $0.hasPrefix("spotify:track:") ? String($0.dropFirst("spotify:track:".count)) : nil }
        Task { @MainActor [weak self] in self?.model?.spotifyPlaybackDidChange(expectedTrackID: id) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        TrackToastPanel.shared.dismiss()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard openMainWindow != nil else { return true }
        // A visible track toast isn't a main window. Dock clicks must also restore minimized windows.
        showMainWindow()
        return false
    }

    @objc private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.level == .normal && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if !openingWindow, let openMainWindow {
            openingWindow = true
            openMainWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let info = model.dockPlaybackInfo
        let menu = NSMenu(title: "Albumer")
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: info.status))
        if let track = info.track {
            addInformation(info.counter.map { "\($0) · \(track)" } ?? track, symbol: "music.note", to: menu)
            if let artist = info.artist, !artist.isEmpty { addInformation(artist, symbol: "person.crop.circle", to: menu) }
            if let album = info.album {
                addInformation(info.year.map { "\(album) · \($0)" } ?? album, symbol: "opticaldisc", to: menu)
            }
            if let device = info.device { addInformation("Spotify · \(device)", symbol: info.deviceSymbol ?? "airplay.audio", to: menu) }
        }
        menu.addItem(.separator())
        addAction("上一曲", symbol: "backward.end.fill", action: #selector(dockPrevious), enabled: info.canGoPrevious, to: menu)
        addAction(info.isPlaying ? "暂停" : "播放", symbol: info.isPlaying ? "pause.fill" : "play.fill",
                  action: #selector(dockTogglePlayback), enabled: info.canTogglePlayback, to: menu)
        addAction("下一曲", symbol: "forward.end.fill", action: #selector(dockNext), enabled: info.canGoNext, to: menu)
        menu.addItem(.separator())
        addAction("打开 Albumer", symbol: "macwindow", action: #selector(showMainWindow), enabled: true, to: menu)
        Task { await model.refreshPlayback() }
        return menu
    }

    private func addInformation(_ text: String, symbol: String, to menu: NSMenu) {
        let title = text.count > 72 ? String(text.prefix(71)) + "…" : text
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = text
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func addAction(_ title: String, symbol: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        menu.addItem(item)
    }

    @objc private func dockPrevious() {
        guard let model else { return }
        Task { await model.performDockAction(.previous) }
    }
    @objc private func dockTogglePlayback() {
        guard let model else { return }
        Task { await model.performDockAction(.togglePlayback) }
    }
    @objc private func dockNext() {
        guard let model else { return }
        Task { await model.performDockAction(.next) }
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
