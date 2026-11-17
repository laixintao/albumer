import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @MotionPreference private var reduceMotion
    @FocusState private var searchFocused: Bool
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library

    var body: some View {
        ZStack {
            RoomBackground(accent: model.accent, moving: model.isForeground && model.playback?.isPlaying == true && model.selectedAlbum != nil, lightPosition: model.lightPosition)
            VStack(spacing: 0) {
                toolbar
                if model.connection == .restoring {
                    Spacer(); ProgressView().controlSize(.small); Spacer()
                } else if !model.isConnected {
                    WelcomeView(model: model)
                } else if let album = model.selectedAlbum {
                    StageView(model: model, album: album)
                        .id(album.id)
                } else {
                    CollectionView(model: model).id(model.isSearching)
                    if model.hasPlayback { MiniPlayer(model: model) }
                }
                if model.isConnected && (model.selectedAlbum != nil || !model.hasPlayback) { sourceFooter }
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color(red: 0.76, green: 0.64, blue: 0.46))
                        .accessibilityHidden(true)
                    Text(notice).font(.system(size: 12)).foregroundStyle(Color.paper.opacity(0.85))
                        .lineLimit(2).help(notice)
                    Spacer(minLength: 12)
                    GlyphButton(symbol: "arrow.clockwise", label: "重试", size: 26) { Task { await model.retry() } }
                    GlyphButton(symbol: "xmark", label: "关闭提示", size: 26) { model.notice = nil }
                }
                .padding(.horizontal, 24).padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.room.opacity(0.97))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.paper.opacity(0.08)).frame(height: 1) }
                .padding(.top, 50)
                .transition(reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity))
                .task(id: notice) {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard !Task.isCancelled, model.notice == notice else { return }
                    model.notice = nil
                }
            }
        }
        .foregroundStyle(Color.paper).preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 640)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: model.isSearching)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notice)
        .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
        .task {
            await model.start()
            if ProcessInfo.processInfo.arguments.contains("--stage"), let album = model.playingAlbum.flatMap({ $0.isAllowed ? $0 : nil }) ?? model.albums.first {
                model.select(album)
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--playing") { await model.play(album) }
            }
        }
        .onChange(of: scenePhase) { _, phase in model.setForeground(phase == .active) }
        .onChange(of: model.isSearching) { _, searching in searchFocused = searching }
        .onChange(of: model.showDevices) { _, showing in if !showing { model.cancelPendingPlayback() } }
        .onExitCommand {
            if model.selectedAlbum != nil { model.selectedAlbum = nil }
            else if model.isSearching { model.showCollection() }
        }
        .background(WindowReader(model: model))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.isDemo {
                Button { Task { await model.exitDemo() } } label: {
                    Text("预览 · 无音频").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.quiet)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.04), in: Capsule())
                }.buttonStyle(.plain).help("退出预览").accessibilityIdentifier("exitPreview")
            }
            Spacer(minLength: 12)
            if model.isSearching && model.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.quiet)
                    TextField("专辑或艺人", text: Binding(get: { model.query }, set: { model.query = $0; model.searchChanged() })).textFieldStyle(.plain).font(.system(size: 13))
                        .focused($searchFocused).accessibilityIdentifier("albumSearch")
                        .onSubmit { model.searchChanged() }
                    if !model.query.isEmpty {
                        GlyphButton(symbol: "xmark", label: "清空搜索", size: 24) { model.query = ""; model.searchChanged() }
                    }
                }.padding(.leading, 12).padding(.trailing, 6).frame(width: 260, height: 36)
                    .background(.white.opacity(0.055), in: Capsule())
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if model.isConnected {
                if !model.isSearching && model.selectedAlbum == nil {
                    GlyphButton(symbol: "person.2", label: "按艺人分组", active: groupByArtist, size: 32) { groupByArtist.toggle() }
                        .accessibilityValue(groupByArtist ? "已开启" : "已关闭")
                        .accessibilityIdentifier("groupByArtist")
                    Menu {
                        Picker("排序", selection: $sortOrder) {
                            ForEach(AlbumSortOrder.allCases, id: \.self) { order in Text(order.label).tag(order) }
                        }.pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.paper.opacity(sortOrder == .library ? 0.6 : 1))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.white.opacity(sortOrder == .library ? 0 : 0.1)))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(sortOrder.label).accessibilityLabel("专辑排序").accessibilityValue(sortOrder.label)
                    .accessibilityIdentifier("albumSortOrder")
                    GlyphButton(symbol: "arrow.clockwise", label: "同步收藏", size: 32) { Task { await model.refreshCollection() } }
                        .disabled(model.isLoading).opacity(model.isLoading ? 0.3 : 1).accessibilityIdentifier("refreshCollection")
                }
                GlyphButton(symbol: "magnifyingglass", label: "搜索专辑", active: model.isSearching) {
                    model.selectedAlbum = nil
                    model.isSearching.toggle()
                    if !model.isSearching { model.query = "" }
                    model.searchChanged(); searchFocused = model.isSearching
                }.accessibilityIdentifier("searchButton")
                GlyphButton(symbol: "square.grid.2x2", label: "收藏", active: !model.isSearching && model.selectedAlbum == nil) { model.showCollection() }
                    .accessibilityIdentifier("collectionButton")
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 16).padding(.horizontal, 4)
                GlyphButton(symbol: "airplay.audio", label: "播放设备", active: model.showDevices) {
                    model.showDevices.toggle(); Task { await model.refreshDevices() }
                }.accessibilityIdentifier("devicesButton")
                    .popover(isPresented: $model.showDevices, arrowEdge: .bottom) { DevicesPanel(model: model) }
            }
            GlyphButton(symbol: "slider.horizontal.3", label: "设置") { model.showSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        .padding(.horizontal, 22).frame(height: 46).padding(.top, 4)
    }
    private var sourceFooter: some View {
        HStack {
            SpotifyAttribution(album: model.selectedAlbum)
            Spacer()
            if let device = model.playback?.device ?? model.preferredDevice {
                Button { model.showDevices = true; Task { await model.refreshDevices() } } label: {
                    HStack(spacing: 7) { Image(systemName: device.symbol); Text(device.name) }
                        .font(.system(size: 11)).foregroundStyle(Color.quiet)
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 24).frame(height: 36)
    }
}

struct CollectionView: View {
    @Bindable var model: AppModel
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library
    @State private var tailVisible = false
    @State private var position = ScrollPosition(y: 0)
    var body: some View {
        VStack(spacing: 0) {
            if model.albums.isEmpty && !model.isLoading {
                Spacer()
                VStack(spacing: 18) {
                    Image(systemName: model.isSearching ? "magnifyingglass" : "square.stack").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Color.quiet)
                    Text(emptyMessage)
                        .font(.system(size: 14)).foregroundStyle(Color.quiet)
                    if !model.hasLoadedPage && !(model.isSearching && model.query.isEmpty) {
                        Button("重试") { Task { await model.retry() } }.buttonStyle(QuietButtonStyle())
                    } else if !model.isSearching {
                        Button("搜索专辑") { model.isSearching = true; model.searchChanged() }.buttonStyle(QuietButtonStyle())
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 11, alignment: .top)], alignment: .leading, spacing: 11) {
                        if model.isLoading && model.albums.isEmpty {
                            ForEach(0..<24) { _ in
                                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.035)).aspectRatio(1, contentMode: .fit)
                            }
                        } else {
                            ForEach(AlbumArtistGroup.make(from: model.albums, grouped: !model.isSearching && groupByArtist, order: model.isSearching ? .library : sortOrder)) { group in
                                Section {
                                    ForEach(group.albums) { album in
                                        AlbumCard(album: album, playing: model.playingAlbum?.id == album.id && model.playback?.isPlaying == true,
                                                  showYear: !model.isSearching && sortOrder != .library) { model.select(album) }.id(album.id)
                                    }
                                } header: {
                                    if let name = group.name {
                                        HStack {
                                            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.paper.opacity(0.72))
                                            Spacer()
                                        }.padding(.top, 14).padding(.bottom, 3)
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                }
                            }
                        }
                    }.scrollTargetLayout().padding(.horizontal, 22).padding(.top, 8)
                    if model.nextOffset != nil {
                        Group {
                            if model.loadMoreFailed {
                                GlyphButton(symbol: "arrow.clockwise", label: "重试加载更多") { Task { await model.loadMoreAlbums() } }
                            } else {
                                ProgressView().controlSize(.mini).opacity(model.isLoading ? 1 : 0.3)
                            }
                        }.frame(height: 38).accessibilityIdentifier("loadMoreAlbums")
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                tailVisible = visible
                                loadVisibleTail()
                            }
                    }
                    Color.clear.frame(height: 16)
                }.scrollIndicators(.hidden)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                        guard position.isPositionedByUser, model.selectedAlbum == nil else { return }
                        if model.isSearching { model.searchOffset = max(0, offset) }
                        else { model.collectionOffset = max(0, offset) }
                    }
                    .task { position.scrollTo(y: model.isSearching ? model.searchOffset : model.collectionOffset) }
                    .accessibilityIdentifier("albumCollection")
            }
        }
        .onChange(of: model.isLoading) { _, _ in loadVisibleTail() }
        .onChange(of: model.nextOffset) { _, _ in loadVisibleTail() }
        .onChange(of: groupByArtist) { _, _ in arrangementChanged() }
        .onChange(of: sortOrder) { _, _ in arrangementChanged() }
        .onAppear { loadVisibleTail() }
    }
    private var needsCompleteLibrary: Bool { !model.isSearching && (groupByArtist || sortOrder != .library) }
    private func arrangementChanged() {
        guard !model.isSearching else { return }
        model.collectionOffset = 0; position.scrollTo(y: 0)
        loadVisibleTail()
    }
    private func loadVisibleTail() {
        guard !model.isLoading, !model.loadMoreFailed else { return }
        if needsCompleteLibrary { Task { await model.loadRemainingCollection() } }
        else if tailVisible { Task { await model.loadMoreAlbums() } }
    }
    private var emptyMessage: String {
        if model.isSearching && model.query.isEmpty { return "专辑或艺人" }
        if !model.hasLoadedPage { return "专辑尚未同步" }
        return model.isSearching ? "没有找到专辑" : "还没有收藏的专辑"
    }
}

struct AlbumCard: View {
    let album: Album
    let playing: Bool
    var showYear = false
    let action: () -> Void
    @State private var hovered = false
    @MotionPreference private var reduceMotion
    var body: some View {
        Button(action: action) {
            AlbumArtwork(album: album, radius: 4)
                .overlay(alignment: .topLeading) {
                    if showYear, let year = album.releaseYear {
                        Text(String(year)).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.paper).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                            .padding(7).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.paper.opacity(playing ? 0.8 : hovered ? 0.45 : 0), lineWidth: playing ? 1.5 : 1).padding(-3))
                .shadow(color: .black.opacity(hovered ? 0.5 : 0.16), radius: hovered ? 12 : 4, y: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .help("\(album.name) — \(album.artist)")
        .accessibilityLabel("\(album.name)，\(album.artist)\(album.releaseYear.map { "，\($0) 年" } ?? "")")
        .accessibilityIdentifier("album-\(album.id)")
    }
}

