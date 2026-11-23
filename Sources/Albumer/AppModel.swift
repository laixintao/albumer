import SwiftUI
import AppKit
import Observation

@MainActor @Observable
final class ArtistCatalog {
    let artist: Artist
    var albums: [Album] = []
    var savedIDs: Set<String> = []
    var nextOffset: Int? = 0
    var isLoading = false
    var error: String?
    var scrollOffset: CGFloat = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(artist: Artist) { self.artist = artist }
    func albums(saved: Bool) -> [Album] {
        AlbumSortOrder.newestFirst.arrange(albums.filter { savedIDs.contains($0.id) == saved })
    }
}

@MainActor @Observable
final class AppModel {
    enum Destination {
        case collection, album(Album), artist(ArtistCatalog)
    }
    enum Connection { case restoring, disconnected, connected }
    var connection: Connection = .restoring
    var albums: [Album] = []
    var selectedAlbum: Album?
    var selectedArtist: ArtistCatalog?
    private(set) var navigationHistory: [Destination] = []
    var backRequest = UUID()
    var playback: PlaybackSnapshot?
    var devices: [PlaybackDevice] = []
    var preferredDevice: PlaybackDevice?
    var isRefreshingDevices = false
    var savedIDs: Set<String> = []
    var checkedSavedIDs: Set<String> = []
    var query = ""
    var isSearching = false
    var isLoading = false
    var hasLoadedPage = false
    var loadMoreFailed = false
    var collectionOffset: CGFloat = 0
    var searchOffset: CGFloat = 0
    var tracks: [AlbumTrack] = []
    var isLoadingTracks = false
    var tracksFailed = false
    var isBusy = false
    var isSaving = false
    var savingAlbumID: String?
    var checkingSavedIDs: Set<String> = []
    var saveErrors: [String: String] = [:]
    var isDisconnecting = false
    var isAuthorizing = false
    var showSettings = false
    var notice: String?
    var isDemo: Bool
    var isForeground = true
    var nextOffset: Int?
    var clientID: String
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let client: SpotifyClient
    @ObservationIgnored private let liveService: any SpotifyService
    @ObservationIgnored private let localStore: LocalStore
    @ObservationIgnored private let dockArtwork: DockArtworkController
    @ObservationIgnored private let trackAnnouncements: TrackAnnouncementController
    @ObservationIgnored private var announcementMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var announcementMetadataAlbumID: AlbumID?
    @ObservationIgnored private var metadataAttempts: [AlbumID: Date] = [:]
    private var playbackAlbums: [String: Album] = [:]
    @ObservationIgnored private var playbackChangeTask: Task<Void, Never>?
    @ObservationIgnored private let injectedCacheAccount: String?
    @ObservationIgnored private let hasInjectedService: Bool
    @ObservationIgnored private var cacheAccount: String?
    @ObservationIgnored private var cacheGeneration: UUID?
    @ObservationIgnored private var library: CachedLibrary?
    private var trackCache: [String: CachedTracks] = [:]
    @ObservationIgnored private var artistCache: [String: Artist] = [:]
    @ObservationIgnored private var artistCatalogs: [String: ArtistCatalog] = [:]
    @ObservationIgnored private var savedVersions: [String: Int] = [:]
    @ObservationIgnored private var tracksTask: Task<Void, Never>?
    @ObservationIgnored private var service: any SpotifyService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var rememberedDeviceID: String?
    @ObservationIgnored private var lastDeviceRefresh = Date.distantPast
    @ObservationIgnored private var devicesTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var playbackRevision = 0
    @ObservationIgnored private var lastBackgroundNotice: (message: String, date: Date)?
    @ObservationIgnored private var pollSuspended = false

    init(demo: Bool = false, service: (any SpotifyService)? = nil, localStore: LocalStore = .shared,
         cacheAccount: String? = nil, dockArtwork: DockArtworkController = .shared,
         trackAnnouncements: TrackAnnouncementController = TrackAnnouncementController(),
         auth: SpotifyAuth = SpotifyAuth(), preferences: UserDefaults = .standard) {
        self.auth = auth; self.preferences = preferences
        client = SpotifyClient(auth: auth)
        liveService = service ?? client
        self.service = demo ? FixtureSpotifyService() : liveService
        self.localStore = localStore; injectedCacheAccount = cacheAccount
        self.dockArtwork = dockArtwork; self.trackAnnouncements = trackAnnouncements
        hasInjectedService = service != nil
        isDemo = demo
        clientID = preferences.string(forKey: "spotifyClientID") ?? ""
    }
    var isConnected: Bool { connection == .connected }
    var hasPlayback: Bool { playback?.item != nil }
    var dockPlaybackInfo: DockPlaybackInfo {
        let tracks = playingAlbumID.flatMap { trackCache[$0.rawValue]?.tracks } ?? []
        return DockPlaybackInfo(playback: playback, album: playingAlbum, tracks: tracks, connected: isConnected, busy: isBusy, resolvedAlbumID: playingAlbumID)
    }
    var playingAlbumID: AlbumID? {
        let contextTracks = playback?.context?.albumID.flatMap { trackCache[$0.rawValue]?.tracks }
        return PlaybackIdentity.albumID(for: playback, contextTracks: contextTracks)
    }
    var playingAlbum: Album? {
        guard let id = playingAlbumID else { return nil }
        if let album = playback?.item?.album, album.albumID == id { return album }
        if let album = selectedAlbum, album.albumID == id { return album }
        return playbackAlbums[id.rawValue] ?? albums.first { $0.albumID == id } ?? library?.albums.first { $0.albumID == id }
            ?? artistCatalogs.values.lazy.compactMap { $0.albums.first { $0.albumID == id } }.first
    }
    var playingArtworkURL: URL? {
        guard let id = playingAlbumID else { return nil }
        if playback?.item?.albumID == id, let artwork = playback?.item?.artwork { return artwork }
        let candidates = [playingAlbum, selectedAlbum, albums.first { $0.albumID == id }, library?.albums.first { $0.albumID == id }]
        return candidates.compactMap { $0 }.first { $0.albumID == id && $0.artwork != nil }?.artwork
    }

    private func updatePlaybackPresentation() {
        if !isDemo { dockArtwork.update(playingArtworkURL) }
        updateTrackAnnouncement()
    }

    private func updateTrackAnnouncement() {
        let id = playingAlbumID
        let cached = id.flatMap { trackCache[$0.rawValue]?.tracks } ?? []
        let announcement = TrackAnnouncement(state: playback, album: playingAlbum, tracks: cached, resolvedAlbumID: id)
        trackAnnouncements.update(announcement, isPlaying: playback?.isPlaying == true)
        guard let track = playback?.item, let id else { return }
        let needsTracks = trackCache[id.rawValue] == nil &&
            ((track.discNumber ?? 1) > 1 || announcement?.total == nil || track.albumID != id)
        let needsAlbum = playingAlbum == nil
        guard needsTracks || needsAlbum, announcementMetadataAlbumID != id,
              Date.now.timeIntervalSince(metadataAttempts[id] ?? .distantPast) >= 30 else { return }
        announcementMetadataTask?.cancel()
        announcementMetadataAlbumID = id
        metadataAttempts[id] = .now
        let session = sessionGeneration
        let service = service
        announcementMetadataTask = Task {
            defer {
                if !Task.isCancelled, announcementMetadataAlbumID == id { announcementMetadataAlbumID = nil }
            }
            let album = needsAlbum ? try? await service.album(id) : nil
            let tracks = needsTracks ? try? await service.albumTracks(id) : nil
            guard !Task.isCancelled, session == sessionGeneration, playingAlbumID == id else { return }
            if let album, album.albumID == id { playbackAlbums[id.rawValue] = album }
            if let tracks { trackCache[id.rawValue] = CachedTracks(tracks: tracks, updatedAt: .now) }
            announcementMetadataAlbumID = nil
            updatePlaybackPresentation()
        }
    }

    private func resetTrackAnnouncements() {
        trackAnnouncements.reset()
        metadataAttempts = [:]; playbackAlbums = [:]
        announcementMetadataTask?.cancel(); announcementMetadataTask = nil; announcementMetadataAlbumID = nil
        playbackChangeTask?.cancel(); playbackChangeTask = nil
    }

    /// Local Spotify notifications are only refresh hints; the Web API confirms the actual playback.
    func spotifyPlaybackDidChange(expectedTrackID: String?) {
        guard isConnected, !isDemo, !pollSuspended else { return }
        playbackChangeTask?.cancel()
        let session = sessionGeneration
        playbackChangeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                for _ in 0..<3 {
                    try Task.checkCancellation()
                    guard session == sessionGeneration, isConnected, !pollSuspended else { return }
                    // An Albumer playback command already runs its own confirmation loop.
                    if isBusy { return }
                    if !isRefreshing {
                        await refreshPlayback()
                        if expectedTrackID == nil || playback?.item?.id == expectedTrackID { return }
                    }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch { /* Coalesce rapid changes into the latest confirmed track. */ }
        }
    }

    /// Closing and reopening a WindowGroup must not restore auth or reload navigation a second time.
    func startIfNeeded() async -> Bool {
        if let startupTask { await startupTask.value; return false }
        let task = Task { await start() }
        startupTask = task
        await task.value
        return true
    }

    func start() async {
        if isDemo { connection = .connected; await loadPage(offset: 0); await refreshPlayback(); restartPolling(); return }
        do {
            try await localStore.prepare()
            connection = try await auth.restore() ? .connected : .disconnected
            if isConnected {
                await restoreLocalData()
                await refreshCollection(force: false); await refreshPlayback(); restartPolling()
            }
        } catch { connection = .disconnected; report(error) }
    }
    func connect() {
        guard !isAuthorizing, !isDisconnecting else { return }
        clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.set(clientID, forKey: "spotifyClientID")
        isAuthorizing = true; notice = nil
        connectTask = Task {
            defer { isAuthorizing = false }
            do {
                try await auth.authorize(clientID: clientID) { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                try Task.checkCancellation()
                await finishConnection()
            } catch { report(error) }
        }
    }
    func finishConnection() async {
        // The sheet's onDisappear cancels an unfinished authorization. End that
        // phase before dismissing it, so dismissal cannot cancel library loading.
        isAuthorizing = false
        generation += 1; sessionGeneration += 1; resetArtistCatalogs(); pollSuspended = false
        service = liveService; isDemo = false; connection = .connected
        ImageStore.shared.clear()
        albums = []; hasLoadedPage = false; savedIDs = []; checkedSavedIDs = []
        selectedAlbum = nil; playback = nil; resetDevices()
        query = ""; isSearching = false; nextOffset = nil; library = nil; cacheAccount = nil
        collectionOffset = 0; searchOffset = 0; tracks = []; trackCache = [:]; artistCache = [:]
        await client.resetBackoff()
        showSettings = false
        NSApp?.activate(ignoringOtherApps: true)
        await restoreLocalData()
        await refreshCollection(); await refreshPlayback(); restartPolling()
    }
    func cancelAuthorization() {
        guard isAuthorizing else { return }
        connectTask?.cancel()
        Task { await auth.cancelAuthorization() }
    }
    func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true; notice = nil; connection = .disconnected
        defer { isDisconnecting = false }
        generation += 1; sessionGeneration += 1; resetArtistCatalogs()
        pollTask?.cancel(); searchTask?.cancel(); connectTask?.cancel(); tracksTask?.cancel()
        do { try await auth.disconnect() } catch { report(error) }
        service = liveService; isDemo = false; connection = .disconnected
        albums = []; hasLoadedPage = false; selectedAlbum = nil; playback = nil; resetDevices()
        savedIDs = []; checkedSavedIDs = []
        query = ""; isSearching = false; isLoading = false; isBusy = false; isSaving = false
        library = nil; tracks = []; trackCache = [:]; artistCache = [:]
        collectionOffset = 0; searchOffset = 0
        cacheAccount = nil; cacheGeneration = nil
        clientID = ""; preferences.removeObject(forKey: "spotifyClientID")
        dockArtwork.update(nil)
        ImageStore.shared.clear()
        do { try await localStore.removeUserData() }
        catch { notice = "本地数据未能完全删除，请在设置中重试清除本地数据。" }
    }
    func enterDemo() async {
        generation += 1; sessionGeneration += 1; resetArtistCatalogs(); pollTask?.cancel(); searchTask?.cancel()
        service = FixtureSpotifyService(); isDemo = true; connection = .connected
        tracksTask?.cancel(); library = nil; cacheAccount = nil
        tracks = []; trackCache = [:]; artistCache = [:]; collectionOffset = 0; searchOffset = 0
        dockArtwork.update(nil)
        ImageStore.shared.clear()
        notice = nil; showSettings = false; albums = []; hasLoadedPage = false; selectedAlbum = nil; playback = nil; resetDevices()
        savedIDs = []; checkedSavedIDs = []; query = ""; isSearching = false
        nextOffset = nil
        await loadPage(offset: 0); await refreshPlayback(); restartPolling()
    }
    func exitDemo() async {
        generation += 1; sessionGeneration += 1; resetArtistCatalogs(); pollTask?.cancel(); searchTask?.cancel()
        isDemo = false; service = liveService
        tracksTask?.cancel(); library = nil; cacheAccount = nil
        tracks = []; trackCache = [:]; artistCache = [:]; collectionOffset = 0; searchOffset = 0
        ImageStore.shared.clear()
        albums = []; hasLoadedPage = false; playback = nil; selectedAlbum = nil; query = ""; isSearching = false; resetDevices()
        savedIDs = []; checkedSavedIDs = []; nextOffset = nil
        await start()
    }
    func searchChanged() {
        navigationGeneration += 1
        generation += 1
        let generation = generation
        searchTask?.cancel(); nextOffset = nil; loadMoreFailed = false; searchOffset = 0
        if !isSearching, let library {
            albums = library.albums; nextOffset = library.nextOffset; hasLoadedPage = true; isLoading = false
            Task { await refreshCollection(force: false) }
            return
        }
        albums = []; hasLoadedPage = false
        guard !isSearching || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { isLoading = false; return }
        isLoading = true
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(320)); try Task.checkCancellation() } catch { return }
            guard generation == self.generation else { return }
            await loadPage(offset: 0)
        }
    }
    func showCollection() {
        resetNavigation()
        if isSearching { isSearching = false; query = ""; searchChanged() }
        else { Task { await refreshCollection(force: false) } }
    }
    private func restoreLocalData() async {
        guard !isDemo else { return }
        let session = sessionGeneration
        if hasInjectedService { cacheAccount = injectedCacheAccount }
        else {
            if await auth.accountIdentifier() == nil, let id = try? await client.accountIdentifier(), session == sessionGeneration {
                try? await auth.setAccountIdentifier(id)
            }
            guard session == sessionGeneration else { return }
            cacheAccount = await auth.cacheIdentifier()
        }
        guard let cacheAccount else { return }
        let cached = await localStore.library(account: cacheAccount)
        let cacheGeneration = await localStore.generation()
        let rememberedDeviceID = await localStore.preferredDeviceID(account: cacheAccount)
        guard session == sessionGeneration else { return }
        self.cacheGeneration = cacheGeneration
        self.rememberedDeviceID = rememberedDeviceID
        if let cached {
            library = cached; albums = cached.albums; nextOffset = cached.nextOffset; hasLoadedPage = true
            savedIDs = Set(albums.map(\.id)); checkedSavedIDs = savedIDs
        }
    }
    func refreshCollection(force: Bool = true) async {
        guard isConnected, !isSearching, !isLoading else { return }
        if !force, let library, Date.now.timeIntervalSince(library.updatedAt) < 60 { return }
        generation += 1
        searchTask?.cancel()
        await loadPage(offset: 0)
    }
    func loadPage(offset: Int, append: Bool = false, allRemaining: Bool = false) async {
        let generation = generation
        let service = service
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = isSearching
        let savedVersions = savedVersions
        if searching && query.isEmpty { albums = []; isLoading = false; return }
        isLoading = true; loadMoreFailed = false
        defer { if generation == self.generation { isLoading = false } }
        do {
            var gathered: [Album] = []
            var next: Int?
            var currentOffset = offset
            var visited = Set<Int>()
            // Refresh the whole loaded portion, so returning never collapses an
            // expanded library to its first network page or loses scroll position.
            let target = allRemaining ? Int.max : (searching || append ? 1 : max(1, library?.albums.count ?? 0))
            repeat {
                guard visited.insert(currentOffset).inserted else { break }
                let result = try await searching ? service.searchAlbums(query: query, offset: currentOffset) : service.savedAlbums(offset: currentOffset)
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                gathered += result.albums
                next = result.nextOffset.flatMap { $0 > currentOffset ? $0 : nil }
                if let next { currentOffset = next }
            } while next != nil && gathered.count < target && visited.count < 100
            guard generation == self.generation else { return }
            // A library snapshot started before a successful save must not undo that save.
            guard searching || savedVersions == self.savedVersions else { return }
            var ids = Set<String>()
            albums = ((append ? albums : []) + gathered).filter { ids.insert($0.id).inserted }
            nextOffset = next; hasLoadedPage = true
            if !searching {
                let previousIDs = Set(library?.albums.map(\.id) ?? [])
                let loadedIDs = Set(albums.map(\.id))
                savedIDs.subtract(previousIDs); savedIDs.formUnion(loadedIDs)
                checkedSavedIDs.subtract(previousIDs)
                checkedSavedIDs.formUnion(loadedIDs)
                for catalog in artistCatalogs.values {
                    checkedSavedIDs.formUnion(catalog.albums.map(\.id))
                    catalog.savedIDs.subtract(previousIDs)
                    catalog.savedIDs.formUnion(loadedIDs)
                }
                let updated = CachedLibrary(albums: albums, nextOffset: next, updatedAt: append ? library?.updatedAt ?? .now : .now)
                library = updated
                if let cacheAccount, !isDemo { await localStore.saveLibrary(updated, account: cacheAccount, generation: cacheGeneration) }
            }
            updatePlaybackPresentation()
        } catch { if generation == self.generation { loadMoreFailed = append; report(error, quietly: hasLoadedPage) } }
    }
    func loadMoreAlbums() async {
        guard !isLoading, let nextOffset else { return }
        await loadPage(offset: nextOffset, append: true)
    }
    func loadRemainingCollection() async {
        guard isConnected, !isSearching, !isLoading, !loadMoreFailed, let nextOffset else { return }
        await loadPage(offset: nextOffset, append: true, allRemaining: true)
    }

    func select(_ album: Album) {
        navigationGeneration += 1
        if selectedAlbum?.id != album.id { navigationHistory.append(destination) }
        presentAlbum(album)
    }

    func openAlbum(from announcement: TrackAnnouncement) async {
        guard isConnected, let id = announcement.albumID else { return }
        trackAnnouncements.dismiss(announcement.id)
        showSettings = false
        navigationGeneration += 1
        let navigation = navigationGeneration
        let session = sessionGeneration
        let cached = [announcement.album, playingAlbum, selectedAlbum].compactMap { $0 }.first { $0.albumID == id }
            ?? albums.first { $0.albumID == id } ?? library?.albums.first { $0.albumID == id }
            ?? artistCatalogs.values.lazy.compactMap { $0.albums.first { $0.albumID == id } }.first
        if let cached { select(cached); return }
        do {
            // Retain the clicked toast's album identity even if Spotify has already moved on.
            let album = try await service.album(id)
            guard !Task.isCancelled, session == sessionGeneration, navigation == navigationGeneration,
                  isConnected, !showSettings else { return }
            guard album.albumID == id else { throw SpotifyError.invalidResponse }
            select(album)
        } catch {
            guard session == sessionGeneration, navigation == navigationGeneration else { return }
            report(error)
        }
    }

    private func presentAlbum(_ album: Album) {
        selectedArtist = nil
        selectedAlbum = album
        updatePlaybackPresentation()
        tracks = trackCache[album.id]?.tracks ?? []; tracksFailed = false
        tracksTask?.cancel()
        tracksTask = Task { await loadTracks(album) }
        let session = sessionGeneration
        Task {
            guard session == sessionGeneration else { return }
            await checkSaved(album)
        }
    }

    func checkSaved(_ album: Album) async {
        guard !checkedSavedIDs.contains(album.id), !checkingSavedIDs.contains(album.id) else { return }
        let session = sessionGeneration
        let version = savedVersions[album.id]
        checkingSavedIDs.insert(album.id); saveErrors[album.id] = nil
        defer { if session == sessionGeneration { checkingSavedIDs.remove(album.id) } }
        do {
            let saved = try await service.isSaved(album.albumID)
            guard session == sessionGeneration, version == savedVersions[album.id] else { return }
            checkedSavedIDs.insert(album.id)
            if saved { savedIDs.insert(album.id) } else { savedIDs.remove(album.id) }
        } catch {
            guard session == sessionGeneration, !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            saveErrors[album.id] = NetworkRetry.message(for: error)
            report(error, quietly: true)
        }
    }

    private var destination: Destination {
        if let selectedAlbum { return .album(selectedAlbum) }
        if let selectedArtist { return .artist(selectedArtist) }
        return .collection
    }
    var canGoBack: Bool { selectedAlbum != nil || selectedArtist != nil || isSearching }
    var returnsToAlbumGrid: Bool {
        if case .album = navigationHistory.last { return false }
        return selectedAlbum != nil
    }
    var backLabel: String {
        switch navigationHistory.last {
        case .album(let album): "返回 \(album.name)"
        case .artist(let catalog): "返回 \(catalog.artist.name)"
        default: isSearching ? "返回搜索结果" : "返回收藏"
        }
    }
    // The view handles cover geometry before committing a back navigation.
    func requestBack() { navigationGeneration += 1; backRequest = UUID() }
    func goBack() {
        navigationGeneration += 1
        guard let previous = navigationHistory.popLast() else {
            if selectedAlbum != nil || selectedArtist != nil { resetNavigation() }
            else if isSearching { showCollection() }
            return
        }
        tracksTask?.cancel()
        selectedAlbum = nil; selectedArtist = nil
        switch previous {
        case .collection: break
        case .album(let album): presentAlbum(album)
        case .artist(let catalog): selectedArtist = catalog
        }
    }
    func resetNavigation() {
        navigationGeneration += 1
        tracksTask?.cancel()
        selectedAlbum = nil; selectedArtist = nil; navigationHistory = []
    }
    private func resetArtistCatalogs() {
        resetTrackAnnouncements()
        for catalog in artistCatalogs.values { catalog.task?.cancel() }
        artistCatalogs = [:]; savedVersions = [:]
        isSaving = false; savingAlbumID = nil; checkingSavedIDs = []; saveErrors = [:]
        lastBackgroundNotice = nil
        resetNavigation()
    }
    func openArtist(_ artist: Artist) {
        guard let id = artist.id, !id.isEmpty, selectedArtist?.artist.id != id else { return }
        navigationGeneration += 1
        navigationHistory.append(destination)
        let catalog = artistCatalogs[id] ?? ArtistCatalog(artist: artist)
        artistCatalogs[id] = catalog
        tracksTask?.cancel()
        selectedAlbum = nil; selectedArtist = catalog
    }
    func loadArtistCatalog(_ catalog: ArtistCatalog) async {
        if let task = catalog.task { await task.value; return }
        guard catalog.nextOffset != nil else { return }
        let task = Task { await fetchArtistCatalog(catalog) }
        catalog.task = task
        await task.value
        catalog.task = nil
    }
    private func fetchArtistCatalog(_ catalog: ArtistCatalog) async {
        guard let id = catalog.artist.id else { return }
        let session = sessionGeneration
        let service = service
        catalog.isLoading = true; catalog.error = nil
        defer { catalog.isLoading = false }
        do {
            while let offset = catalog.nextOffset {
                try Task.checkCancellation()
                let page = try await service.artistAlbums(id, offset: offset)
                let versions = savedVersions
                let flags = try await service.savedAlbums(page.albums.map(\.albumID))
                try Task.checkCancellation()
                guard session == sessionGeneration else { return }
                guard flags.count == page.albums.count else { throw SpotifyError.invalidResponse }
                var known = Set(catalog.albums.map(\.id))
                for (album, flag) in zip(page.albums, flags) {
                    // A save made while the request was in flight takes precedence.
                    let saved = versions[album.id] == savedVersions[album.id] ? flag : savedIDs.contains(album.id)
                    checkedSavedIDs.insert(album.id)
                    if saved { savedIDs.insert(album.id); catalog.savedIDs.insert(album.id) }
                    else { savedIDs.remove(album.id); catalog.savedIDs.remove(album.id) }
                    if known.insert(album.id).inserted { catalog.albums.append(album) }
                }
                catalog.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                updatePlaybackPresentation()
            }
        } catch {
            if session == sessionGeneration && !Task.isCancelled { catalog.error = NetworkRetry.message(for: error) }
        }
    }

    func artistPortrait(for artist: Artist) async -> URL? {
        if let portrait = artist.portrait { return portrait }
        guard let id = artist.id, !id.isEmpty else { return nil }
        if let cached = artistCache[id] { return cached.portrait }
        let session = sessionGeneration
        // Portraits are optional: missing images or metadata must not interrupt playback.
        guard let detail = try? await service.artist(id), session == sessionGeneration, !Task.isCancelled else { return nil }
        artistCache[id] = detail
        return detail.portrait
    }

    /// Optional hover metadata: never replace the selected album's tracks or raise an error banner.
    func albumDuration(for album: Album) async -> Int? {
        let session = sessionGeneration
        let service = service
        guard !Task.isCancelled else { return nil }
        if trackCache[album.id] == nil, let cacheAccount, !isDemo {
            let cached = await localStore.tracks(album: album.id, account: cacheAccount)
            guard session == sessionGeneration, !Task.isCancelled else { return nil }
            trackCache[album.id] = cached
        }
        let cached = trackCache[album.id]
        if let cached, Date.now.timeIntervalSince(cached.updatedAt) < 86400,
           let duration = totalDuration(cached.tracks, for: album) {
            return duration
        }
        do {
            let fetched = try await service.albumTracks(album.albumID)
            guard session == sessionGeneration, !Task.isCancelled else { return nil }
            guard let duration = totalDuration(fetched, for: album) else { return nil }
            trackCache[album.id] = CachedTracks(tracks: fetched, updatedAt: .now)
            if let cacheAccount, !isDemo { await localStore.saveTracks(fetched, album: album.id, account: cacheAccount, generation: cacheGeneration) }
            return duration
        } catch {
            guard session == sessionGeneration, !Task.isCancelled else { return nil }
            return cached.flatMap { totalDuration($0.tracks, for: album) }
        }
    }

    private func totalDuration(_ tracks: [AlbumTrack], for album: Album) -> Int? {
        guard !tracks.isEmpty, tracks.count == album.totalTracks, tracks.allSatisfy({ $0.durationMS > 0 }) else { return nil }
        return tracks.reduce(0) { $0 + $1.durationMS }
    }

    func loadTracks(_ album: Album) async {
        let session = sessionGeneration
        let service = service
        isLoadingTracks = true
        defer { if selectedAlbum?.id == album.id && session == sessionGeneration { isLoadingTracks = false } }
        if trackCache[album.id] == nil, let cacheAccount, !isDemo {
            let cached = await localStore.tracks(album: album.id, account: cacheAccount)
            guard selectedAlbum?.id == album.id, session == sessionGeneration, !Task.isCancelled else { return }
            trackCache[album.id] = cached
        }
        if let cached = trackCache[album.id] {
            tracks = cached.tracks
            if Date.now.timeIntervalSince(cached.updatedAt) < 86400 { return }
        }
        do {
            let tracks = try await service.albumTracks(album.albumID)
            guard selectedAlbum?.id == album.id, session == sessionGeneration, !Task.isCancelled else { return }
            self.tracks = tracks; tracksFailed = false
            trackCache[album.id] = CachedTracks(tracks: tracks, updatedAt: .now)
            if playingAlbumID == album.albumID { updateTrackAnnouncement() }
            if let cacheAccount, !isDemo { await localStore.saveTracks(tracks, album: album.id, account: cacheAccount, generation: cacheGeneration) }
        } catch {
            if !Task.isCancelled && selectedAlbum?.id == album.id && session == sessionGeneration { tracksFailed = true }
        }
    }
    func toggleSaved(_ album: Album) async {
        guard !isSaving, checkedSavedIDs.contains(album.id) else { return }
        let session = sessionGeneration
        isSaving = true; savingAlbumID = album.id; saveErrors[album.id] = nil
        defer { if session == sessionGeneration { isSaving = false; savingAlbumID = nil } }
        let saving = !savedIDs.contains(album.id)
        do {
            try await service.setSaved(album.albumID, saved: saving)
            try Task.checkCancellation()
            guard session == sessionGeneration else { return }
            if saving { savedIDs.insert(album.id) } else { savedIDs.remove(album.id) }
            savedVersions[album.id, default: 0] += 1
            for catalog in artistCatalogs.values {
                if saving { catalog.savedIDs.insert(album.id) } else { catalog.savedIDs.remove(album.id) }
            }
            // A successful mutation is enough to update the UI. Refetching the entire library
            // adds traffic and can make an unrelated read failure look like a failed save.
            if var library {
                let wasLoaded = library.albums.contains { $0.id == album.id }
                library.albums.removeAll { $0.id == album.id }
                if saving { library.albums.insert(album, at: 0) }
                if let offset = library.nextOffset {
                    library.nextOffset = max(0, offset + (saving && !wasLoaded ? 1 : (!saving && wasLoaded ? -1 : 0)))
                }
                self.library = library
                if !isSearching { albums = library.albums; nextOffset = library.nextOffset }
                if let cacheAccount, !isDemo { await localStore.saveLibrary(library, account: cacheAccount, generation: cacheGeneration) }
            } else if !isSearching {
                albums.removeAll { $0.id == album.id }
                if saving { albums.insert(album, at: 0) }
            }
        } catch {
            guard session == sessionGeneration, !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            saveErrors[album.id] = NetworkRetry.message(for: error)
            report(error, quietly: true)
        }
    }
    func play(_ album: Album) async {
        guard !isBusy, album.restrictions == nil else { return }
        let session = sessionGeneration
        if preferredDevice == nil { await refreshDevices() }
        guard session == sessionGeneration, !isBusy else { return }
        guard let device = preferredDevice, let id = device.id, device.isSelectable else {
            notice = "未发现可用设备，请打开 Spotify 后重试播放。"; return
        }
        if playingAlbumID == album.albumID && playback?.device?.id == id {
            await perform(playback?.isPlaying == true ? .pause : .resume); return
        }
        guard album.isAllowed else { return }
        await startAlbum(album, device: id)
    }
    private func startAlbum(_ album: Album, device: String) async {
        guard !isBusy else { return }
        let session = sessionGeneration
        isBusy = true; defer { if session == sessionGeneration { isBusy = false } }
        do {
            try await service.playAlbum(album.albumID, device: device)
            guard session == sessionGeneration else { return }
            try await confirm { $0?.context?.uri == album.albumID.uri && $0?.device?.id == device && $0?.isPlaying == true && $0?.shuffleState == false && $0?.repeatState == "off" }
        } catch { if session == sessionGeneration { report(error) } }
    }
    func togglePlayback() async {
        if let selectedAlbum { await play(selectedAlbum) }
        else if hasPlayback { await perform(playback?.isPlaying == true ? .pause : .resume) }
    }
    func performDockAction(_ action: DockPlaybackAction) async {
        let info = dockPlaybackInfo
        guard info.allows(action) else { return }
        switch action {
        case .previous: await perform(.previous)
        case .togglePlayback: await perform(info.isPlaying ? .pause : .resume)
        case .next: await perform(.next)
        }
    }
    func perform(_ command: PlayerCommand) async {
        guard !isBusy else { return }
        let session = sessionGeneration
        isBusy = true; defer { if session == sessionGeneration { isBusy = false } }
        let previousID = playback?.item?.id
        do {
            try await service.command(command, device: playback?.device?.id)
            guard session == sessionGeneration else { return }
            try await confirm { state in
                switch command {
                case .pause: state?.isPlaying == false
                case .resume: state?.isPlaying == true
                case .next: state?.item?.id != previousID
                case .previous: state?.item?.id != previousID || (state?.progressMS ?? 99999) < 3000
                case .seek(let ms): abs((state?.progressMS ?? -10000) - ms) < 2500
                case .volume(let value): state?.device?.volumePercent == value
                }
            }
        } catch { if session == sessionGeneration { report(error) } }
    }
    func refreshDevices() async {
        if let devicesTask { await devicesTask.value; return }
        guard isConnected, !isBusy, !pollSuspended else { return }
        let session = sessionGeneration
        let task = Task { await loadDevices() }
        devicesTask = task
        await task.value
        if session == sessionGeneration { devicesTask = nil }
    }
    private func loadDevices() async {
        let session = sessionGeneration
        isRefreshingDevices = true
        defer { if session == sessionGeneration { isRefreshingDevices = false } }
        do {
            let devices = try await service.devices()
            guard session == sessionGeneration else { return }
            self.devices = devices
            lastDeviceRefresh = .now
            let available = devices.filter(\.isSelectable)
            // Follow Spotify's active output; otherwise retain the user's choice,
            // then default to a computer or the first controllable device.
            preferredDevice = available.first(where: \.isActive)
                ?? available.first(where: { $0.id == preferredDevice?.id })
                ?? available.first(where: { $0.id == rememberedDeviceID })
                ?? available.first(where: { $0.type.lowercased() == "computer" })
                ?? available.first
        } catch { if session == sessionGeneration { report(error, quietly: true) } }
    }
    private func resetDevices() {
        devicesTask?.cancel(); devicesTask = nil
        devices = []; preferredDevice = nil; rememberedDeviceID = nil
        isRefreshingDevices = false; lastDeviceRefresh = .distantPast
    }
    func chooseDevice(_ device: PlaybackDevice) async {
        guard !isBusy, let id = device.id, device.isSelectable else { return }
        let session = sessionGeneration
        if let devicesTask { await devicesTask.value }
        guard session == sessionGeneration, !isBusy, devices.contains(where: { $0.id == id && $0.isSelectable }) else { return }
        isBusy = true
        defer { if session == sessionGeneration { isBusy = false } }
        do {
            if playback?.device?.id != id {
                try await service.transfer(to: id, play: playback?.isPlaying == true)
            }
            guard session == sessionGeneration else { return }
            // A fresh idle client may return 204 until the first album is started.
            // Do not block that first start waiting for an existing playback context.
            if hasPlayback { try await confirm { $0?.device?.id == id } }
            preferredDevice = device; rememberedDeviceID = id
            if let cacheAccount, !isDemo { await localStore.savePreferredDeviceID(id, account: cacheAccount, generation: cacheGeneration) }
        } catch { if session == sessionGeneration { report(error) } }
    }
    func openSpotify() {
        let session = sessionGeneration
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else { NSWorkspace.shared.open(URL(string: "https://www.spotify.com/download/mac/")!) }
        Task {
            for _ in 0..<10 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard isConnected, session == sessionGeneration else { return }
                await refreshDevices()
                if preferredDevice != nil { return }
            }
        }
    }
    func refreshPlayback() async {
        guard isConnected, !isRefreshing, !isBusy else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let session = sessionGeneration
        let revision = playbackRevision
        do {
            let state = try await service.playback()
            // A slower poll must not replace a newer playback-command confirmation.
            if session == sessionGeneration, revision == playbackRevision, !isBusy {
                await applyPlayback(state)
                if (isForeground || lastDeviceRefresh == .distantPast) && Date.now.timeIntervalSince(lastDeviceRefresh) >= 30 {
                    await refreshDevices()
                }
            }
        } catch { if session == sessionGeneration { report(error, quietly: true) } }
    }
    private func applyPlayback(_ state: PlaybackSnapshot?) async {
        playbackRevision += 1
        playback = state
        if let device = state?.device, device.isSelectable {
            preferredDevice = device
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
            else { devices.append(device) }
        }
        updatePlaybackPresentation()
    }
    private func confirm(_ matches: (PlaybackSnapshot?) -> Bool) async throws {
        let sessionGeneration = sessionGeneration
        let service = service
        for attempt in 0..<5 {
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 250 : 650))
            let state = try await service.playback()
            guard sessionGeneration == self.sessionGeneration else { throw CancellationError() }
            await applyPlayback(state)
            if matches(state) { return }
        }
        throw SpotifyError.playbackUnconfirmed
    }
    func setForeground(_ foreground: Bool) {
        let returning = foreground && !isForeground
        isForeground = foreground
        restartPolling()
        if returning && isConnected && !isDemo && !isSearching && selectedAlbum == nil && !isLoading && !pollSuspended {
            Task { await refreshCollection(force: false) }
        }
    }
    private var playbackPollDelay: TimeInterval {
        let regular: TimeInterval = isForeground ? (playback?.isPlaying == true ? 5 : 15) : 20
        guard let playback, playback.isPlaying, let item = playback.item else { return regular }
        let remaining = Double(item.durationMS) / 1000 - playback.position()
        // Check near an expected natural track boundary, including while the main window is hidden.
        return remaining > 0.2 ? min(regular, max(0.5, remaining + 0.15)) : regular
    }

    func restartPolling() {
        pollTask?.cancel()
        guard isConnected, !pollSuspended else { return }
        pollTask = Task {
            await refreshPlayback()
            while !Task.isCancelled && isConnected && !pollSuspended {
                do { try await Task.sleep(for: .seconds(playbackPollDelay)) } catch { return }
                await refreshPlayback()
            }
        }
    }
    func retry() async {
        pollSuspended = false; notice = nil
        await client.resetBackoff()
        await refreshPlayback()
        if loadMoreFailed { await loadMoreAlbums() } else { await loadPage(offset: 0) }
        restartPolling()
    }
    private func report(_ error: Error, quietly: Bool = false) {
        guard !(error is CancellationError) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        if quietly && NetworkRetry.isTransient(error) { return }
        if let error = error as? SpotifyError {
            if error == .signedOut { connection = .disconnected; pollTask?.cancel(); resetTrackAnnouncements() }
            if error == .quotaExceeded { pollSuspended = true; pollTask?.cancel() }
            if error == .noDevice {
                preferredDevice = nil
                if quietly { return }
                Task { await refreshDevices() }
            }
        }
        let message = NetworkRetry.message(for: error)
        if quietly {
            if let last = lastBackgroundNotice, last.message == message, Date.now.timeIntervalSince(last.date) < 60 { return }
            lastBackgroundNotice = (message, .now)
        }
        notice = message
    }
}

