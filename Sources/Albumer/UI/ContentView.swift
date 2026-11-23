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
        observedContent
        .navigationTitle(windowTitle)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
        .task {
            guard await model.startIfNeeded(), !Task.isCancelled else { return }
            if ProcessInfo.processInfo.arguments.contains("--stage"),
               let album = model.playingAlbum.flatMap({ $0.isAllowed ? $0 : nil }) ?? model.albums.first {
                model.select(album)
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--playing") { await model.play(album) }
            }
        }
        .onExitCommand { model.requestBack() }
        .background(WindowReader(model: model))
    }

    // Keep independently type-checked sections small for the Xcode 26 release compiler.
    private var pageContent: some View {
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
        .scrollIndicators(.never)
        .background(Color.contentBackground)
        .frame(minWidth: 820, minHeight: 600)
        .coordinateSpace(name: AlbumInsertion.coordinateSpace)
    }

    private var transitionContent: some View {
        pageContent
            .overlayPreferenceValue(AlbumArtworkDestinationKey.self) { destination in
                insertionOverlay(destination)
            }
            .overlayPreferenceValue(AlbumReturnDestinationKey.self) { destinations in
                returnOverlay(destinations)
            }
        .environment(\.returningAlbumID, returning?.album.id)
        .task(id: returning?.id) {
            guard let id = returning?.id else { return }
            // A removed/offscreen card must never leave an invisible target or a stuck overlay.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            if returning?.id == id { returning = nil }
        }
    }

    private var observedContent: some View {
        transitionContent
        .onChange(of: model.backRequest) { _, _ in goBack() }
        .onChange(of: model.selectedArtist?.artist.id) { _, _ in
            if model.selectedAlbum == nil { insertion = nil }
            if model.selectedAlbum != nil { returning = nil }
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
    }

    private func insertionOverlay(_ destination: AlbumArtworkDestination?) -> some View {
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

    private func returnOverlay(_ destinations: [String: [Anchor<CGRect>]]) -> some View {
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .clipped()
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
                    if model.hasPlayback {
                        CurrentAlbumLink(model: model, album: model.playingAlbum, selectAlbum: selectAlbum)
                            .frame(maxWidth: 280, alignment: .leading)
                    }
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
                .scrollIndicators(.never)
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
    let album: Album?
    let selectAlbum: (Album, CGRect) -> Void
    @State private var artworkFrame = CGRect.zero
    @State private var loadedArtwork: NSImage?
    @State private var loadedURL: URL?
    @Environment(\.returningAlbumID) private var returningAlbumID
    private var playing: Bool { model.playback?.isPlaying == true }
    private var info: DockPlaybackInfo { model.dockPlaybackInfo }
    private var title: String { info.album ?? info.track ?? "正在播放" }
    private var artwork: NSImage? {
        guard let url = model.playingArtworkURL else { return nil }
        return loadedURL == url ? loadedArtwork : ImageStore.shared.cachedImage(at: url)
    }

    var body: some View {
        Button {
            if let album { selectAlbum(album, artworkFrame) }
            else if let announcement = TrackAnnouncement(state: model.playback, album: nil, tracks: [], resolvedAlbumID: model.playingAlbumID) {
                Task { await model.openAlbum(from: announcement) }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if let artwork {
                        Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                    }
                }
                    .frame(width: 48, height: 48)
                    .opacity(album != nil && returningAlbumID == album?.id ? 0 : 1)
                    .anchorPreference(key: AlbumReturnDestinationKey.self, value: .bounds) { anchor in
                        album.map { [$0.id: [anchor]] } ?? [:]
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumInsertion.coordinateSpace)) } action: {
                        artworkFrame = $0
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Label(playing ? "正在播放" : "已暂停", systemImage: playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(playing ? Color.accentColor : Color.secondary)
                    Text(title).font(.body.weight(.medium)).lineLimit(1)
                    if let artist = info.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.playingAlbumID != nil {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .controlGlass(cornerRadius: 16, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(model.playingAlbumID == nil)
        .help("查看正在播放的专辑：\(title)")
        .accessibilityLabel("\(playing ? "正在播放" : "已暂停")，\(title)，\(info.artist ?? "")")
        .accessibilityIdentifier("currentAlbum")
        .task(id: model.playingArtworkURL) {
            let url = model.playingArtworkURL
            loadedURL = url
            loadedArtwork = url.flatMap { ImageStore.shared.cachedImage(at: $0) }
            guard let url else { return }
            let image = await ImageStore.shared.image(at: url)
            guard !Task.isCancelled else { return }
            loadedArtwork = image
        }
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
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var artworkFrame = CGRect.zero
    @State private var showDetails = false
    @State private var detailsHovered = false

    private var highlighted: Bool { hoverEnabled && returningAlbumID == nil && (hovered || focused || detailsHovered) }

    var body: some View {
        Button { showDetails = false; action(artworkFrame) } label: {
            VStack(alignment: .leading, spacing: 7) {
                AlbumArtwork(album: album)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumInsertion.coordinateSpace)) } action: {
                        artworkFrame = $0
                    }
                    .opacity(returningAlbumID == album.id ? 0 : 1)
                    .anchorPreference(key: AlbumReturnDestinationKey.self, value: .bounds) { [album.id: [$0]] }
                HStack(spacing: 4) {
                    if current {
                        PlaybackIndicator(playing: playing)
                        Text(playing ? "正在播放" : "已暂停").foregroundStyle(Color.accentColor)
                    } else {
                        Text(album.name).foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                    if showYear, let year = album.releaseYear {
                        Text(String(year)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.caption).lineLimit(1)
                .frame(height: 18)
            }
            .padding(5)
            .background(highlighted ? Color.primary.opacity(0.06) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(current ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(Array(album.artists.enumerated()), id: \.offset) { _, artist in
                if artist.id != nil {
                    Button("查看 \(artist.name)", systemImage: "person.crop.circle") { model.openArtist(artist) }
                }
            }
            if !model.isDemo {
                Link("在 Spotify 中打开", destination: album.spotifyURL)
            }
        }
        .focused($focused)
        .onHover { hovered = $0 }
        .onDisappear { hovered = false; detailsHovered = false; showDetails = false }
        .task(id: highlighted) {
            guard highlighted else {
                do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() }
                catch { return }
                showDetails = false
                return
            }
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation() }
            catch { return }
            showDetails = true
        }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) {
            AlbumCardDetails(model: model, album: album)
                .onHover { detailsHovered = $0 }
                .onDisappear { detailsHovered = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(album.name)，\(album.artist)\(album.releaseYear.map { "，\($0) 年" } ?? "")，\(album.totalTracks) 首\(current ? (playing ? "，正在播放" : "，已暂停") : "")")
        .accessibilityIdentifier("album-\(album.id)")
    }
}

private struct AlbumCardDetails: View {
    let model: AppModel
    let album: Album
    @State private var duration: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(album.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(album.artists.enumerated()), id: \.offset) { _, artist in
                ArtistLink(model: model, artist: artist)
            }
            HStack(spacing: 12) {
                Label(album.releaseYear.map(String.init) ?? "—", systemImage: "calendar")
                Label("\(album.totalTracks) 首", systemImage: "music.note.list")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let duration {
                Label(PlaybackProgress.time(Double(duration) / 1000), systemImage: "clock")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            SpotifyAttribution(album: model.isDemo ? nil : album)
        }
        .padding(18).frame(width: 260, alignment: .leading)
        .task { duration = await model.albumDuration(for: album) }
    }
}
