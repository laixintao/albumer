import SwiftUI
import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    enum Connection { case restoring, disconnected, connected }
    var connection: Connection = .restoring
    var albums: [Album] = []
    var selectedAlbum: Album?
    var playback: PlaybackSnapshot?
    var devices: [PlaybackDevice] = []
    var preferredDevice: PlaybackDevice?
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
    var history = ListeningHistory()
    var isBusy = false
    var isSaving = false
    var isAuthorizing = false
    var showSettings = false
    var showDevices = false
    var notice: String?
    var isDemo: Bool
    var isForeground = true
    var nextOffset: Int?
    var clientID: String
    var accent = Color(red: 0.69, green: 0.55, blue: 0.38)
    var lightPosition = UnitPoint.center
    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let client: SpotifyClient
    @ObservationIgnored private let liveService: any SpotifyService
    @ObservationIgnored private let localStore: LocalStore
    @ObservationIgnored private let injectedCacheAccount: String?
    @ObservationIgnored private let hasInjectedService: Bool
    @ObservationIgnored private var cacheAccount: String?
    @ObservationIgnored private var library: CachedLibrary?
    @ObservationIgnored private var trackCache: [String: CachedTracks] = [:]
    @ObservationIgnored private var tracksTask: Task<Void, Never>?
    @ObservationIgnored private var listeningCounter = ListeningCounter()
    @ObservationIgnored private var lastHistoryWrite = Date.distantPast
    @ObservationIgnored private var service: any SpotifyService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var pendingAlbum: Album?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var pollSuspended = false

    init(demo: Bool = false, service: (any SpotifyService)? = nil, localStore: LocalStore = .shared, cacheAccount: String? = nil) {
        auth = SpotifyAuth()
        client = SpotifyClient(auth: auth)
        liveService = service ?? client
        self.service = demo ? FixtureSpotifyService() : liveService
        self.localStore = localStore; injectedCacheAccount = cacheAccount
        hasInjectedService = service != nil
        isDemo = demo
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
    }
    var isConnected: Bool { connection == .connected }
    var hasPlayback: Bool { playback?.item != nil }
    var playingAlbum: Album? { playback?.item?.album }

    func start() async {
        if isDemo { connection = .connected; await loadPage(offset: 0); await refreshPlayback(); restartPolling(); return }
        do {
            connection = try await auth.restore() ? .connected : .disconnected
            if isConnected {
                await restoreLocalData()
                await refreshCollection(force: false); await refreshPlayback(); restartPolling()
            }
        } catch { connection = .disconnected; report(error) }
    }
    func connect() {
        guard !isAuthorizing else { return }
        clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: "spotifyClientID")
        isAuthorizing = true; notice = nil
        connectTask = Task {
            defer { isAuthorizing = false }
            do {
                try await auth.authorize(clientID: clientID) { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                await finishConnection()
            } catch { report(error) }
        }
    }
    func finishConnection() async {
        // The sheet's onDisappear cancels an unfinished authorization. End that
        // phase before dismissing it, so dismissal cannot cancel library loading.
        isAuthorizing = false
        generation += 1; sessionGeneration += 1; pollSuspended = false
        service = liveService; isDemo = false; connection = .connected
        ImageStore.shared.clear()
        albums = []; hasLoadedPage = false; savedIDs = []; checkedSavedIDs = []
        selectedAlbum = nil; playback = nil; preferredDevice = nil
        query = ""; isSearching = false; nextOffset = nil; library = nil; cacheAccount = nil
        collectionOffset = 0; searchOffset = 0; tracks = []; trackCache = [:]
        listeningCounter = ListeningCounter()
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
        generation += 1; sessionGeneration += 1
        pollTask?.cancel(); searchTask?.cancel(); connectTask?.cancel(); tracksTask?.cancel()
        do { try await auth.disconnect() } catch { report(error); return }
        service = liveService; isDemo = false; connection = .disconnected
        albums = []; hasLoadedPage = false; selectedAlbum = nil; playback = nil; devices = []; preferredDevice = nil
        savedIDs = []; checkedSavedIDs = []; pendingAlbum = nil
        query = ""; isSearching = false; isLoading = false; isBusy = false; isSaving = false
        library = nil; tracks = []; trackCache = [:]; history = ListeningHistory(); listeningCounter = ListeningCounter()
        collectionOffset = 0; searchOffset = 0
        if let cacheAccount { await localStore.removeAccountCache(cacheAccount) }
        cacheAccount = nil
        DockArtworkController.shared.update(nil)
        ImageStore.shared.clear()
    }
    func enterDemo() async {
        generation += 1; sessionGeneration += 1; pollTask?.cancel(); searchTask?.cancel()
        service = FixtureSpotifyService(); isDemo = true; connection = .connected
        tracksTask?.cancel(); library = nil; cacheAccount = nil; history = ListeningHistory(); listeningCounter = ListeningCounter()
        tracks = []; trackCache = [:]; collectionOffset = 0; searchOffset = 0
        DockArtworkController.shared.update(nil)
        ImageStore.shared.clear()
        notice = nil; showSettings = false; albums = []; hasLoadedPage = false; selectedAlbum = nil; preferredDevice = nil
        savedIDs = []; checkedSavedIDs = []; query = ""; isSearching = false
        nextOffset = nil
        await loadPage(offset: 0); await refreshPlayback(); restartPolling()
    }
    func exitDemo() async {
        generation += 1; sessionGeneration += 1; pollTask?.cancel(); searchTask?.cancel()
        isDemo = false; service = liveService
        tracksTask?.cancel(); library = nil; cacheAccount = nil; history = ListeningHistory(); listeningCounter = ListeningCounter()
        tracks = []; trackCache = [:]; collectionOffset = 0; searchOffset = 0
        ImageStore.shared.clear()
        albums = []; hasLoadedPage = false; playback = nil; selectedAlbum = nil; query = ""; isSearching = false; preferredDevice = nil
        savedIDs = []; checkedSavedIDs = []; nextOffset = nil
        await start()
    }
    func searchChanged() {
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
        selectedAlbum = nil
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
        let history = await localStore.history(account: cacheAccount)
        guard session == sessionGeneration else { return }
        self.history = history
        listeningCounter = history.session ?? ListeningCounter()
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
            var ids = Set<String>()
            albums = ((append ? albums : []) + gathered).filter { ids.insert($0.id).inserted }
            nextOffset = next; hasLoadedPage = true
            if !searching {
                savedIDs = Set(albums.map(\.id)); checkedSavedIDs = savedIDs
                let updated = CachedLibrary(albums: albums, nextOffset: next, updatedAt: append ? library?.updatedAt ?? .now : .now)
                library = updated
                if let cacheAccount, !isDemo { await localStore.saveLibrary(updated, account: cacheAccount) }
            }
        } catch { if generation == self.generation { loadMoreFailed = append; report(error) } }
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
        selectedAlbum = album
        tracks = trackCache[album.id]?.tracks ?? []; tracksFailed = false
        tracksTask?.cancel()
        tracksTask = Task { await loadTracks(album) }
        Task {
            if let color = await ImageStore.shared.color(for: album), selectedAlbum?.id == album.id { accent = color }
            guard !checkedSavedIDs.contains(album.id) else { return }
            let generation = generation
            do {
                let saved = try await service.isSaved(album.albumID)
                guard generation == self.generation else { return }
                checkedSavedIDs.insert(album.id)
                if saved { savedIDs.insert(album.id) } else { savedIDs.remove(album.id) }
            } catch { report(error) }
        }
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
            if let cacheAccount, !isDemo { await localStore.saveTracks(tracks, album: album.id, account: cacheAccount) }
        } catch {
            if !Task.isCancelled && selectedAlbum?.id == album.id && session == sessionGeneration { tracksFailed = true }
        }
    }
    func toggleSaved(_ album: Album) async {
        guard !isSaving, checkedSavedIDs.contains(album.id) else { return }
        let session = sessionGeneration
        isSaving = true; defer { if session == sessionGeneration { isSaving = false } }
        let saving = !savedIDs.contains(album.id)
        do {
            try await service.setSaved(album.albumID, saved: saving)
            guard session == sessionGeneration else { return }
            if saving { savedIDs.insert(album.id) } else { savedIDs.remove(album.id) }
            if var library {
                library.albums.removeAll { $0.id == album.id }
                if saving { library.albums.insert(album, at: 0) }
                library.updatedAt = .distantPast; self.library = library
                if let cacheAccount, !isDemo { await localStore.saveLibrary(library, account: cacheAccount) }
            }
            if !isSearching { await refreshCollection() }
        } catch { if session == sessionGeneration { report(error) } }
    }
    func play(_ album: Album) async {
        guard !isBusy, album.isAllowed, album.restrictions == nil else { return }
        if playback?.context?.uri == album.albumID.uri {
            await perform(playback?.isPlaying == true ? .pause : .resume); return
        }
        guard let device = playback?.device ?? preferredDevice, let id = device.id, !device.isRestricted else {
            pendingAlbum = album; showDevices = true; await refreshDevices(); return
        }
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
            listeningCounter.beganAlbum()
            _ = listeningCounter.observe(playback)
            pendingAlbum = nil
        } catch { if session == sessionGeneration { report(error) } }
    }
    func togglePlayback() async {
        if let selectedAlbum { await play(selectedAlbum) }
        else if hasPlayback { await perform(playback?.isPlaying == true ? .pause : .resume) }
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
        let session = sessionGeneration
        do {
            let devices = try await service.devices()
            if session == sessionGeneration { self.devices = devices }
        } catch { if session == sessionGeneration { report(error) } }
    }
    func cancelPendingPlayback() { pendingAlbum = nil }
    func chooseDevice(_ device: PlaybackDevice) async {
        guard !isBusy, let id = device.id, !device.isRestricted else { return }
        let session = sessionGeneration
        isBusy = true
        do {
            try await service.transfer(to: id, play: pendingAlbum == nil && playback?.isPlaying == true)
            guard session == sessionGeneration else { return }
            preferredDevice = device
            // A fresh idle client may return 204 until the first album is started.
            // Do not block that first start waiting for an existing playback context.
            if pendingAlbum == nil && hasPlayback { try await confirm { $0?.device?.id == id } }
            let album = pendingAlbum
            pendingAlbum = nil; isBusy = false; showDevices = false
            if let album { await startAlbum(album, device: id) }
        } catch { if session == sessionGeneration { isBusy = false; report(error) } }
    }
    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else { NSWorkspace.shared.open(URL(string: "https://www.spotify.com/download/mac/")!) }
        Task {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                guard showDevices else { return }
                await refreshDevices()
                if !devices.isEmpty { return }
            }
        }
    }
    func refreshPlayback() async {
        guard isConnected, !isRefreshing, !isBusy else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let session = sessionGeneration
        do {
            let state = try await service.playback()
            if session == sessionGeneration { await applyPlayback(state) }
        } catch { if session == sessionGeneration { report(error) } }
    }
    private func applyPlayback(_ state: PlaybackSnapshot?) async {
        playback = state
        if !isDemo { DockArtworkController.shared.update(state?.item?.album) }
        let event = listeningCounter.observe(state)
        if let album = event.album { history.albums[album, default: 0] += 1 }
        if let track = event.track { history.tracks[track, default: 0] += 1 }
        if !event.isEmpty || Date.now.timeIntervalSince(lastHistoryWrite) >= 15 {
            history.session = listeningCounter; lastHistoryWrite = .now
            if let cacheAccount, !isDemo { await localStore.saveHistory(history, account: cacheAccount) }
        }
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
    func restartPolling() {
        pollTask?.cancel()
        guard isConnected, !pollSuspended else { return }
        pollTask = Task {
            await refreshPlayback()
            while !Task.isCancelled && isConnected && !pollSuspended {
                do { try await Task.sleep(for: .seconds(isForeground ? (playback?.isPlaying == true ? 5 : 15) : 20)) } catch { return }
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
    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        if let error = error as? SpotifyError {
            if error == .signedOut { connection = .disconnected; pollTask?.cancel() }
            if error == .quotaExceeded { pollSuspended = true; pollTask?.cancel() }
            if error == .noDevice { preferredDevice = nil; showDevices = true; Task { await refreshDevices() } }
        }
        notice = error.localizedDescription
    }
}

