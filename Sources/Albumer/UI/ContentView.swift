import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFocused: Bool
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library
    @MotionPreference private var reduceMotion
    @State private var insertion: AlbumInsertion?
    @State private var returning: AlbumInsertion?
    @State private var detailFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice { noticeBanner(notice) }
            if model.connection == .restoring {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isConnected {
                WelcomeView(model: model)
            } else {
                if let album = model.selectedAlbum {
                    StageView(model: model, album: album, inserting: insertion?.album.id == album.id,
                              artworkFrameChanged: { detailFrame = $0 }).id(album.id)
                } else if let catalog = model.selectedArtist {
                    ArtistView(model: model, catalog: catalog, selectAlbum: selectAlbum).id(catalog.artist.id)
                } else {
                    CollectionView(model: model, selectAlbum: selectAlbum).id(model.isSearching)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(Color.contentBackground)
        .frame(minWidth: 820, minHeight: 600)
        .coordinateSpace(name: AlbumInsertion.coordinateSpace)
        .overlayPreferenceValue(AlbumArtworkDestinationKey.self) { destination in
            GeometryReader { geometry in
                if let insertion, let destination,
                   destination.albumID == insertion.album.id,
                   model.selectedAlbum?.id == insertion.album.id {
                    AlbumInsertionOverlay(insertion: insertion, destination: geometry[destination.bounds]) {
                        if self.insertion?.id == insertion.id { self.insertion = nil }
                    }
                    .id(insertion.id)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .clipped()
        }
        .overlayPreferenceValue(AlbumReturnDestinationKey.self) { destinations in
            GeometryReader { geometry in
                if let returning {
                    let candidates = (destinations[returning.album.id] ?? []).map { geometry[$0] }
                    let viewport = CGRect(origin: .zero, size: geometry.size)
                    let destination = candidates.last { frame in
                        !frame.isEmpty && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                    }
                    AlbumReturnOverlay(returning: returning, destination: destination) {
                        if self.returning?.id == returning.id { self.returning = nil }
                    }
                    .id(returning.id)
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true).clipped()
        }
        .environment(\.returningAlbumID, returning?.album.id)
        .task(id: returning?.id) {
            guard let id = returning?.id else { return }
            // A removed/offscreen card must never leave an invisible target or a stuck overlay.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            if returning?.id == id { returning = nil }
        }
        .onChange(of: model.backRequest) { _, _ in goBack() }
        .onChange(of: model.selectedArtist?.artist.id) { _, _ in
            if model.selectedAlbum == nil { insertion = nil }
            if model.selectedAlbum != nil { returning = nil }
        }
        .navigationTitle(windowTitle)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
        .task {
            await model.start()
            if ProcessInfo.processInfo.arguments.contains("--stage"),
               let album = model.playingAlbum.flatMap({ $0.isAllowed ? $0 : nil }) ?? model.albums.first {
                model.select(album)
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--playing") { await model.play(album) }
            }
        }
        .onChange(of: scenePhase) { _, phase in model.setForeground(phase == .active) }
        .onChange(of: model.isSearching) { _, searching in
            searchFocused = searching; insertion = nil; returning = nil
        }
        .onChange(of: model.connection) { _, _ in insertion = nil; returning = nil }
        .onChange(of: model.selectedAlbum?.id) { _, id in
            if insertion?.album.id != id { insertion = nil }
            if id != nil { returning = nil }
        }
        .onChange(of: model.isForeground) { _, foreground in
            if !foreground { insertion = nil; returning = nil }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { insertion = nil; returning = nil }
        }
        .onChange(of: model.showSettings) { _, showing in
            if showing { insertion = nil; returning = nil }
        }
        .onDisappear { insertion = nil; returning = nil }
        .onExitCommand { model.requestBack() }
        .background(WindowReader(model: model))
    }

    private func goBack() {
        let album = model.selectedAlbum
        let animate = model.returnsToAlbumGrid && !reduceMotion && model.isForeground && insertion == nil
        insertion = nil; returning = nil
        if animate, let album, !detailFrame.isEmpty, !detailFrame.isInfinite {
            returning = AlbumInsertion(album: album, source: detailFrame)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.goBack() }
    }

    private func selectAlbum(_ album: Album, from source: CGRect) {
        returning = nil
        // Only deliberate selections animate; restoring a page never starts playback or motion.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            insertion = !reduceMotion && model.isForeground && !source.isEmpty && !source.isInfinite
                ? AlbumInsertion(album: album, source: source) : nil
            model.select(album)
        }
    }

    private var windowTitle: String {
        if let album = model.selectedAlbum { return album.name }
        if let artist = model.selectedArtist { return artist.artist.name }
        if model.isSearching { return "搜索专辑" }
        return model.isConnected ? "专辑收藏" : "欢迎使用 Albumer"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if model.isConnected {
                if model.selectedAlbum != nil || model.selectedArtist != nil {
                    Button { model.requestBack() } label: {
                        Label(model.backLabel, systemImage: "chevron.left")
                    }
                    .help(model.backLabel)
                    .accessibilityIdentifier("backToCollection")
                } else {
                    AlbumCollectionButton { model.showCollection() }
                        .accessibilityIdentifier("collectionButton")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isDemo {
                Button { Task { await model.exitDemo() } } label: {
                    Label("退出预览", systemImage: "eye.slash")
                }
                .help("预览模式 · 无音频，点按退出")
                .accessibilityIdentifier("exitPreview")
            }
            if model.isConnected {
                if model.isSearching && model.selectedAlbum == nil && model.selectedArtist == nil {
                    TextField("专辑或艺人", text: Binding(
                        get: { model.query },
                        set: { model.query = $0; model.searchChanged() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($searchFocused)
                    .accessibilityIdentifier("albumSearch")
                    .onSubmit { model.searchChanged() }
                }
                if model.selectedAlbum == nil && model.selectedArtist == nil && !model.isSearching {
                    Menu {
                        Toggle("按艺人分组", isOn: $groupByArtist)
                            .accessibilityIdentifier("groupByArtist")
                        Divider()
                        Picker("排序", selection: $sortOrder) {
                            ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }.pickerStyle(.inline)
                    } label: {
                        Label("显示选项", systemImage: "line.3.horizontal.decrease")
                    }
                    .help("分组与排序")
                    .accessibilityIdentifier("albumSortOrder")
                    Button { Task { await model.refreshCollection() } } label: {
                        Label("同步收藏", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    .help("同步收藏")
                    .accessibilityIdentifier("refreshCollection")
                }
                Button {
                    model.resetNavigation()
                    model.isSearching.toggle()
                    if !model.isSearching { model.query = "" }
                    model.searchChanged()
                    searchFocused = model.isSearching
                } label: {
                    Label(model.isSearching ? "结束搜索" : "搜索专辑", systemImage: model.isSearching ? "xmark" : "magnifyingglass")
                }
                .help(model.isSearching ? "结束搜索" : "搜索专辑")
                .accessibilityIdentifier("searchButton")
            }
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                Text(notice).font(.callout).lineLimit(2).help(notice)
                Spacer(minLength: 12)
                Button("重试") { Task { await model.retry() } }.controlSize(.small)
                GlyphButton(symbol: "xmark", label: "关闭提示", size: 24) { model.notice = nil }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
        }
        .background(Color.windowBackground)
        .task(id: notice) {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, model.notice == notice else { return }
            model.notice = nil
        }
    }
}

struct CollectionView: View {
    @Bindable var model: AppModel
    let selectAlbum: (Album, CGRect) -> Void
    @AppStorage("groupAlbumsByArtist") private var groupByArtist = false
    @AppStorage("albumSortOrder") private var sortOrder: AlbumSortOrder = .library
    @State private var tailVisible = false
    @State private var position = ScrollPosition(y: 0)
    @State private var scrolling = false
    @MotionPreference private var reduceMotion
    @Namespace private var albumPositions
    @State private var displayedArrangement: AlbumGridArrangement?
    @State private var rearranging = false
    @State private var rearrangementID = UUID()

    private var preferredArrangement: AlbumGridArrangement {
        AlbumGridArrangement(grouped: !model.isSearching && groupByArtist,
                             order: model.isSearching ? .library : sortOrder)
    }
    private var arrangement: AlbumGridArrangement { displayedArrangement ?? preferredArrangement }

    var body: some View {
        VStack(spacing: 0) {
            GlassControls {
                HStack(spacing: 20) {
                    if let album = model.playingAlbum, album.isAllowed {
                        CurrentAlbumLink(model: model, album: album, selectAlbum: selectAlbum)
                            .frame(maxWidth: 280, alignment: .leading)
                    }
                    if !model.isSearching { RecommendationPromptButton(model: model) }
                    Spacer(minLength: 0)
                    PlaybackDevicesView(model: model)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            if model.albums.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label(emptyMessage, systemImage: model.isSearching ? "magnifyingglass" : "square.stack")
                } actions: {
                    if !model.hasLoadedPage && !(model.isSearching && model.query.isEmpty) {
                        Button("重试") { Task { await model.retry() } }
                    } else if !model.isSearching {
                        Button("搜索专辑") { model.isSearching = true; model.searchChanged() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 184), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        if model.isLoading && model.albums.isEmpty {
                            ForEach(0..<24) { _ in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .aspectRatio(1, contentMode: .fit)
                                    .accessibilityHidden(true)
                            }
                        } else {
                            ForEach(AlbumArtistGroup.make(from: model.albums, grouped: arrangement.grouped, order: arrangement.order)) { group in
                                Section {
                                    ForEach(group.albums) { album in
                                        AlbumCard(
                                            model: model,
                                            album: album,
                                            current: model.playingAlbumID == album.albumID,
                                            playing: model.playback?.isPlaying == true,
                                            showYear: arrangement.order != .library,
                                            hoverEnabled: !scrolling && !rearranging && model.isForeground && !model.showSettings,
                                            action: { source in selectAlbum(album, source) }
                                        )
                                        // Match across artist sections as well as within a section; the cover keeps its size.
                                        .matchedGeometryEffect(id: album.id, in: albumPositions, properties: .position)
                                        .transition(.identity)
                                        .id(album.id)
                                    }
                                } header: {
                                    if let name = group.name {
                                        Group {
                                            if let artist = group.albums.first?.artists.first, artist.id != nil {
                                                ArtistLink(model: model, artist: artist, portrait: false)
                                            } else { Text(name) }
                                        }.font(.headline)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 8)
                                            .accessibilityAddTraits(.isHeader)
                                            .transition(.opacity)
                                    }
                                }
                                .transition(.identity)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(20)
                    .transaction { transaction in
                        if reduceMotion || !model.isForeground {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                    if model.nextOffset != nil {
                        Group {
                            if model.loadMoreFailed {
                                Button("重试加载更多", systemImage: "arrow.clockwise") { Task { await model.loadMoreAlbums() } }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(height: 36)
                        .accessibilityIdentifier("loadMoreAlbums")
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            tailVisible = visible
                            loadVisibleTail()
                        }
                    }
                }
                .scrollPosition($position)
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
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
        .onChange(of: preferredArrangement) { _, _ in arrangementChanged() }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { finishRearrangement() }
        }
        .onChange(of: model.isForeground) { _, foreground in
            if !foreground { finishRearrangement() }
        }
        .onAppear {
            displayedArrangement = preferredArrangement
            loadVisibleTail()
        }
        .onDisappear { finishRearrangement() }
        .task {
            // Refresh on return without waiting for the playback poll interval.
            if model.hasLoadedPage { await model.refreshPlayback() }
        }
    }

    private var needsCompleteLibrary: Bool { !model.isSearching && (groupByArtist || sortOrder != .library) }
    private func arrangementChanged() {
        let target = preferredArrangement
        guard target != displayedArrangement else { return }
        let id = UUID()
        rearrangementID = id
        let animate = !reduceMotion && model.isForeground && !model.isSearching && !model.albums.isEmpty
        rearranging = animate
        withAnimation(animate ? .smooth(duration: 0.32, extraBounce: 0) : nil, completionCriteria: .removed) {
            displayedArrangement = target
        } completion: {
            // A newer menu selection owns the current animation and must not be ended by an older one.
            if rearrangementID == id { rearranging = false }
        }
        loadVisibleTail()
    }
    private func finishRearrangement() {
        rearrangementID = UUID()
        rearranging = false
    }
    private func loadVisibleTail() {
        guard !model.isLoading, !model.loadMoreFailed else { return }
        if needsCompleteLibrary { Task { await model.loadRemainingCollection() } }
        else if tailVisible { Task { await model.loadMoreAlbums() } }
    }
    private var emptyMessage: String {
        if model.isSearching && model.query.isEmpty { return "搜索专辑或艺人" }
        if !model.hasLoadedPage { return "专辑尚未同步" }
        return model.isSearching ? "没有找到专辑" : "还没有收藏的专辑"
    }
}

private struct AlbumGridArrangement: Equatable {
    let grouped: Bool
    let order: AlbumSortOrder
}

private struct CurrentAlbumLink: View {
    @Bindable var model: AppModel
    let album: Album
    let selectAlbum: (Album, CGRect) -> Void
    @State private var artworkFrame = CGRect.zero
    @Environment(\.returningAlbumID) private var returningAlbumID
    private var playing: Bool { model.playback?.isPlaying == true }

    var body: some View {
        Button { selectAlbum(album, artworkFrame) } label: {
            HStack(spacing: 10) {
                AlbumArtwork(album: album, radius: 4).frame(width: 48, height: 48)
                    .opacity(returningAlbumID == album.id ? 0 : 1)
                    .anchorPreference(key: AlbumReturnDestinationKey.self, value: .bounds) { [album.id: [$0]] }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumInsertion.coordinateSpace)) } action: {
                        artworkFrame = $0
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Label(playing ? "正在播放" : "已暂停", systemImage: playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(playing ? Color.accentColor : Color.secondary)
                    Text(album.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .controlGlass(cornerRadius: 16, interactive: true)
        }
        .buttonStyle(.plain)
        .help("查看正在播放的专辑：\(album.name)")
        .accessibilityLabel("\(playing ? "正在播放" : "已暂停")，\(album.name)，\(album.artist)，查看专辑")
        .accessibilityIdentifier("currentAlbum")
    }
}

struct AlbumCard: View {
    let model: AppModel
    let album: Album
    let current: Bool
    let playing: Bool
    var showYear = false
    var hoverEnabled = true
    let action: (CGRect) -> Void
    @Environment(\.returningAlbumID) private var returningAlbumID
    @MotionPreference private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var artworkFrame = CGRect.zero
    @State private var flip = AlbumFlipState()
    @State private var angle = 0.0
    @State private var loadMetadata = false

    private var canHover: Bool { hoverEnabled && returningAlbumID == nil }
    private var highlighted: Bool { canHover && (hovered || focused) }

    var body: some View {
        Button { action(artworkFrame) } label: {
            // Hit testing stays square while the artwork turns edge-on. Motion cannot trigger hover exits.
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        cover.modifier(AlbumCardFace(angle: angle, back: false))
                        AlbumCardBack(model: model, album: album, current: current, playing: playing, loadMetadata: loadMetadata)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(current ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: current ? 3 : 0.5)
                            }
                            .modifier(AlbumCardFace(angle: angle, back: true))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(returningAlbumID == album.id ? 0 : 1)
        .anchorPreference(key: AlbumReturnDestinationKey.self, value: .bounds) { [album.id: [$0]] }
        .contextMenu {
            ForEach(Array(album.artists.enumerated()), id: \.offset) { _, artist in
                if artist.id != nil {
                    Button("查看 \(artist.name)", systemImage: "person.crop.circle") { model.openArtist(artist) }
                }
            }
        }
        .focused($focused)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumInsertion.coordinateSpace)) } action: {
            artworkFrame = $0
        }
        .onHover { inside in
            hovered = inside
            // Handle the event immediately: a quick enter/exit can occur within one render frame.
            updateHighlight()
        }
        .onChange(of: focused) { _, _ in updateHighlight() }
        .onChange(of: canHover) { _, _ in updateHighlight() }
        .onChange(of: reduceMotion) { _, _ in resetMotion(showBack: highlighted) }
        .onDisappear { resetMotion(); hovered = false }
        .task(id: flip.phase) { await animatePhase() }
        .task(id: highlighted) {
            loadMetadata = false
            guard highlighted else { return }
            do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
            guard !Task.isCancelled, highlighted else { return }
            loadMetadata = true
        }
        .zIndex(flip.phase != .front ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(album.name)，\(album.artist)\(album.releaseYear.map { "，\($0) 年" } ?? "")，\(album.totalTracks) 首\(current ? (playing ? "，正在播放" : "，已暂停") : "")")
        .accessibilityIdentifier("album-\(album.id)")
    }

    private var cover: some View {
        AlbumArtwork(album: album)
            .overlay(alignment: .topLeading) {
                if showYear, let year = album.releaseYear {
                    Text(String(year)).font(.caption).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if current {
                    Label(playing ? "正在播放" : "已暂停", systemImage: playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(playing ? Color.accentColor : Color.black.opacity(0.8), in: Capsule())
                        .padding(7)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(current ? Color.accentColor : Color.primary.opacity(highlighted ? 0.25 : 0), lineWidth: current ? 3 : 1)
            }
    }

    private func updateHighlight() {
        guard canHover else { resetMotion(); return }
        if reduceMotion { resetMotion(showBack: highlighted) }
        else { flip.setHighlighted(highlighted) }
    }

    private func resetMotion(showBack: Bool = false) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flip.reset(showBack: showBack)
            angle = showBack ? 180 : 0
            if !showBack { loadMetadata = false }
        }
    }

    private func animatePhase() async {
        guard !reduceMotion, canHover else { return }
        let phase = flip.phase
        do {
            switch phase {
            case .front, .back: return
            case .turningToBack:
                // 360° and 0° are the same face. Reset between turns without rotating backwards.
                if angle == 360 {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { angle = 0 }
                    try await Task.sleep(for: .milliseconds(16))
                }
                withAnimation(.easeInOut(duration: 0.22)) { angle = 180 }
                try await Task.sleep(for: .milliseconds(220))
            case .turningToFront:
                withAnimation(.easeInOut(duration: 0.20)) { angle = 360 }
                try await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
            guard flip.phase == phase else { return }
            flip.finishPhase()
        } catch { /* Removing or disabling the card cancels its remaining motion. */ }
    }
}

private struct AlbumCardBack: View {
    let model: AppModel
    let album: Album
    let current: Bool
    let playing: Bool
    let loadMetadata: Bool
    @State private var duration: Int?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 150
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                HStack(alignment: .top, spacing: 4) {
                    Text(album.name).font(.system(size: compact ? 11 : 13, weight: .semibold))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if current { PlaybackIndicator(playing: playing) }
                }
                HStack(spacing: 6) {
                    if let artist = album.artists.first {
                        ArtistPortrait(model: model, artist: artist, size: compact ? 22 : 28, loadEnabled: loadMetadata)
                    }
                    Text(album.artist.isEmpty ? "未知艺人" : album.artist)
                        .font(.system(size: compact ? 10 : 12)).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                    HStack(spacing: 6) {
                        Label(album.releaseYear.map(String.init) ?? "—", systemImage: "calendar")
                        Spacer(minLength: 0)
                        Label("\(album.totalTracks) 首", systemImage: "music.note.list")
                    }
                    Label(duration.map { PlaybackProgress.time(Double($0) / 1000) } ?? "—:——", systemImage: "clock")
                }
                .font(.system(size: compact ? 10 : 11)).monospacedDigit().foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            }
            .padding(compact ? 9 : 12)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .background {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                GeometryReader { geometry in
                    AlbumArtwork(album: album, radius: 0)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 1.2, opaque: true)
                        // A uniform scrim keeps small white text readable, including on pale covers.
                        .overlay(Color.black.opacity(0.56))
                }
            }
        }
        // Artwork belongs inside the glass surface; placing it behind the glass blurs it a second time.
        .artworkGlass()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
        .task(id: loadMetadata) {
            guard loadMetadata else { return }
            let loaded = await model.albumDuration(for: album)
            guard !Task.isCancelled else { return }
            duration = loaded
        }
    }
}

