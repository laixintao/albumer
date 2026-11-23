import XCTest
import AppKit
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

private actor LibraryService: SpotifyService {
    var albums: [Album]
    var failure: SpotifyError?
    var requestCount = 0
    var albumRequestCount = 0
    let delay: Duration
    let pageSize: Int
    var outputs: [PlaybackDevice] = []
    var state: PlaybackSnapshot?
    var playedOn: [String] = []
    var transfers: [String] = []
    var commandCount = 0
    var deviceRequestCount = 0
    var deviceDelay: Duration = .zero
    var trackResults: [AlbumTrack] = []
    var trackDelay: Duration = .zero
    var trackFailure: SpotifyError?
    var trackRequestCount = 0
    var saveFailure: SpotifyError?
    var savedCheckFailure: SpotifyError?
    var playbackFailure: SpotifyError?
    private var holdNextPlayback = false
    private var heldPlayback: (PlaybackSnapshot?, CheckedContinuation<PlaybackSnapshot?, Error>)?
    var saveDelay: Duration = .zero
    var saveRequests: [Bool] = []

    init(_ albums: [Album], delay: Duration = .zero, pageSize: Int = 50) {
        self.albums = albums; self.delay = delay; self.pageSize = pageSize
    }
    func update(_ albums: [Album], failure: SpotifyError? = nil) {
        self.albums = albums; self.failure = failure
    }
    func savedAlbums(offset: Int) async throws -> AlbumPage {
        requestCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return AlbumPage(albums: Array(albums.dropFirst(offset).prefix(pageSize)), nextOffset: offset + pageSize < albums.count ? offset + pageSize : nil, total: albums.count)
    }
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage { try await savedAlbums(offset: offset) }
    func album(_ id: AlbumID) async throws -> Album {
        albumRequestCount += 1
        if delay != .zero { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        guard let album = albums.first(where: { $0.albumID == id }) else { throw SpotifyError.invalidResponse }
        return album
    }
    func setTracks(_ tracks: [AlbumTrack], delay: Duration = .zero, failure: SpotifyError? = nil) {
        trackResults = tracks; trackDelay = delay; trackFailure = failure
    }
    func albumTracks(_ album: AlbumID) async throws -> [AlbumTrack] {
        trackRequestCount += 1
        // Simulate a response that can arrive even after its consumer is cancelled.
        if trackDelay != .zero { try? await Task.sleep(for: trackDelay) }
        if let trackFailure { throw trackFailure }
        return trackResults
    }
    func configureSave(failure: SpotifyError? = nil, delay: Duration = .zero) { saveFailure = failure; saveDelay = delay }
    func configureSavedCheck(failure: SpotifyError?) { savedCheckFailure = failure }
    func configurePlayback(failure: SpotifyError?) { playbackFailure = failure }
    func isSaved(_ album: AlbumID) async throws -> Bool {
        if let savedCheckFailure { throw savedCheckFailure }
        return albums.contains { $0.albumID == album }
    }
    func setSaved(_ album: AlbumID, saved: Bool) async throws {
        saveRequests.append(saved)
        if saveDelay != .zero { try await Task.sleep(for: saveDelay) }
        if let saveFailure { throw saveFailure }
    }
    func setDevices(_ devices: [PlaybackDevice]) { outputs = devices }
    func delayDevices(_ delay: Duration) { deviceDelay = delay }
    func setPlayback(_ state: PlaybackSnapshot?) { self.state = state }
    func holdPlaybackRead() { holdNextPlayback = true }
    func hasHeldPlayback() -> Bool { heldPlayback != nil }
    func releasePlaybackRead() {
        let held = heldPlayback
        heldPlayback = nil
        if let (snapshot, continuation) = held { continuation.resume(returning: snapshot) }
    }
    func playback() async throws -> PlaybackSnapshot? {
        if let playbackFailure { throw playbackFailure }
        if holdNextPlayback {
            holdNextPlayback = false
            return try await withCheckedThrowingContinuation { heldPlayback = (state, $0) }
        }
        return state
    }
    func devices() async throws -> [PlaybackDevice] {
        deviceRequestCount += 1
        if deviceDelay != .zero { try await Task.sleep(for: deviceDelay) }
        return outputs
    }
    func transfer(to device: String, play: Bool) async throws {
        transfers.append(device)
        state?.device = outputs.first { $0.id == device }
    }
    func playAlbum(_ album: AlbumID, device: String) async throws {
        playedOn.append(device)
        state = PlaybackSnapshot(device: outputs.first { $0.id == device }, isPlaying: true,
                                 context: PlaybackContext(type: "album", uri: album.uri), shuffleState: false, repeatState: "off")
    }
    func command(_ command: PlayerCommand, device: String?) async throws {
        commandCount += 1
        if case .pause = command { state?.isPlaying = false }
        if case .resume = command { state?.isPlaying = true }
    }
}

private final class DisconnectTokens: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: StoredToken? = StoredToken(accessToken: "fixture-access", refreshToken: "fixture-refresh",
                                                  expiresAt: .distantFuture, clientID: "fixture-client")
    func read() throws -> StoredToken? { lock.withLock { token } }
    func write(_ token: StoredToken?) throws { lock.withLock { self.token = token } }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func album(_ name: String, artwork: URL? = nil) -> Album {
        Album(id: name, name: name, artists: [Artist(name: "Artist")], albumType: "album",
              images: artwork.map { [SpotifyImage(url: $0, width: 640, height: 640)] } ?? [], releaseDate: "2020", totalTracks: 10)
    }
    private func device(_ id: String?, type: String = "computer", active: Bool = false, restricted: Bool = false) -> PlaybackDevice {
        PlaybackDevice(id: id, name: id ?? "Unavailable", type: type, isActive: active, isRestricted: restricted,
                       volumePercent: 50, supportsVolume: true)
    }
    private func tracks(count: Int = 10) -> [AlbumTrack] {
        (1...count).map {
            AlbumTrack(spotifyID: "track-\($0)", name: "Track \($0)", artists: [], durationMS: $0 * 1000,
                       trackNumber: $0, discNumber: 1)
        }
    }
    func testDisconnectClearsCredentialsCachesAndLatePlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root.appendingPathComponent("cache"), dataRoot: root.appendingPathComponent("data"))
        let suite = "albumer-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("fixture-client", forKey: "spotifyClientID")
        let tokens = DisconnectTokens()
        let auth = SpotifyAuth(store: tokens)
        let service = LibraryService([album("Private")])
        let model = AppModel(service: service, localStore: store, cacheAccount: "one", auth: auth, preferences: preferences)
        model.setForeground(false)
        await model.finishConnection()
        await service.setPlayback(PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "private-song", name: "Private", artists: [],
                                  durationMS: 180000, trackNumber: 1, discNumber: 1, album: album("Private"))))
        await service.holdPlaybackRead()
        let refresh = Task { await model.refreshPlayback() }
        try await waitUntil { await service.hasHeldPlayback() }
        await model.disconnect()
        await service.releasePlaybackRead()
        await refresh.value
        XCTAssertNil(try tokens.read())
        XCTAssertNil(preferences.string(forKey: "spotifyClientID"))
        XCTAssertEqual(model.clientID, "")
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertNil(model.playback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    func testSingleReleaseInAlbumContextUpdatesToastDockAndDestination() async throws {
        let full = album("Full", artwork: URL(string: "https://example.test/full.png"))
        let single = Album(id: "single", name: "Single", artists: full.artists, albumType: "single",
                           images: [SpotifyImage(url: URL(string: "https://example.test/single.png")!, width: 640, height: 640)],
                           releaseDate: "2019", totalTracks: 1)
        let service = LibraryService([full])
        await service.setTracks(tracks())
        var announcements: [TrackAnnouncement] = []
        let controller = TrackAnnouncementController(wait: { duration in
            if duration == .seconds(1) { await Task.yield() } else { try await Task.sleep(for: duration) }
        }, present: { announcements.append($0) })
        let model = AppModel(service: service, trackAnnouncements: controller)
        model.connection = .connected
        model.selectedAlbum = album("Browsing")
        await service.setPlayback(PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "single-edition", name: "Track 5", artists: [],
            durationMS: 5000, trackNumber: 1, discNumber: 1, album: single, linkedFromID: "track-5"),
            context: PlaybackContext(type: "album", uri: full.albumID.uri)))
        await model.refreshPlayback()
        try await waitUntil { announcements.last?.counter == "5/10" }
        XCTAssertEqual(model.playingAlbumID, full.albumID)
        XCTAssertEqual(model.playingArtworkURL, full.artwork)
        XCTAssertEqual(model.dockPlaybackInfo.album, full.name)
        XCTAssertEqual(model.dockPlaybackInfo.counter, "5/10")
        let toast = try XCTUnwrap(announcements.last)
        XCTAssertEqual(toast.album, full)
        await model.openAlbum(from: toast)
        XCTAssertEqual(model.selectedAlbum, full)
        let commands = await service.commandCount
        XCTAssertEqual(commands, 0)
        controller.reset()
    }

    func testDockPauseControlsCurrentPlaybackWithoutStartingBrowsedAlbum() async {
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        let current = album("Current")
        let browsing = album("Browsing")
        let state = PlaybackSnapshot(isPlaying: true,
                                     item: PlaybackTrack(id: "song", name: "Playing Song", artists: [], durationMS: 180000,
                                                         trackNumber: 1, discNumber: 1, album: current),
                                     context: PlaybackContext(type: "album", uri: current.albumID.uri))
        model.playback = state; model.selectedAlbum = browsing
        await service.setPlayback(state)
        await model.performDockAction(.togglePlayback)
        XCTAssertEqual(model.selectedAlbum, browsing)
        XCTAssertEqual(model.playingAlbumID, current.albumID)
        XCTAssertEqual(model.playback?.isPlaying, false)
        let commands = await service.commandCount
        let starts = await service.playedOn
        XCTAssertEqual(commands, 1)
        XCTAssertTrue(starts.isEmpty)
        model.isBusy = true
        await model.performDockAction(.next)
        let blockedCommands = await service.commandCount
        XCTAssertEqual(blockedCommands, 1)
    }

    func testToastOpensItsCapturedAlbumAfterPlaybackChangesAndPreservesBackNavigation() async throws {
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        let record = album("Toast Album")
        let browsing = album("Browsing")
        model.select(browsing)
        let state = PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "old-track", name: "Toast Song", artists: [],
                                    durationMS: 180000, trackNumber: 1, discNumber: 1, album: record))
        let toast = try XCTUnwrap(TrackAnnouncement(state: state, album: nil, tracks: []))
        model.playback = PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "new-track", name: "New Song", artists: [],
                                         durationMS: 180000, trackNumber: 1, discNumber: 1, album: album("New Album")))
        await model.openAlbum(from: toast)
        XCTAssertEqual(model.selectedAlbum, record)
        XCTAssertEqual(model.playback?.item?.id, "new-track")
        model.goBack()
        XCTAssertEqual(model.selectedAlbum, browsing)
        let commands = await service.commandCount
        let plays = await service.playedOn
        let fetches = await service.albumRequestCount
        XCTAssertEqual(commands, 0); XCTAssertTrue(plays.isEmpty); XCTAssertEqual(fetches, 0)
    }

    func testToastWithPartialAlbumLoadsDetailsByItsCapturedID() async throws {
        let record = album("toast")
        let service = LibraryService([record])
        let model = AppModel(service: service)
        model.connection = .connected
        let state = PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "track", name: "Song", artists: [],
                                    durationMS: 180000, trackNumber: 1, discNumber: 1, album: nil, albumID: record.albumID))
        let toast = try XCTUnwrap(TrackAnnouncement(state: state, album: nil, tracks: []))
        await model.openAlbum(from: toast)
        XCTAssertEqual(model.selectedAlbum, record)
        let fetches = await service.albumRequestCount
        XCTAssertEqual(fetches, 1)
    }

    func testPlaylistSingleFollowsPlaybackAndPausesWithoutRestartingAlbum() async {
        let single = Album(id: "single", name: "Playing Single", artists: [Artist(name: "Artist")],
                           albumType: "single", images: [], releaseDate: "2020", totalTracks: 1)
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        let output = device("mac", active: true)
        await service.setDevices([output])
        await service.setPlayback(PlaybackSnapshot(device: output, isPlaying: true, progressMS: 42000,
            item: PlaybackTrack(id: "song", name: "Playing Song", artists: single.artists,
                                durationMS: 180000, trackNumber: 1, discNumber: 1, album: single),
            context: PlaybackContext(type: "playlist", uri: "spotify:playlist:mix")))
        await model.refreshPlayback()
        XCTAssertTrue(model.hasPlayback)
        XCTAssertEqual(model.playingAlbum, single)
        XCTAssertEqual(model.dockPlaybackInfo.status, "正在播放")
        model.select(single)
        await model.togglePlayback()
        XCTAssertEqual(model.playback?.isPlaying, false)
        XCTAssertEqual(model.dockPlaybackInfo.status, "已暂停")
        let commands = await service.commandCount
        let starts = await service.playedOn
        XCTAssertEqual(commands, 1)
        XCTAssertTrue(starts.isEmpty)
    }

    func testSlowPlaybackPollCannotOverwriteNewerCommandConfirmation() async throws {
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        let state = PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "song", name: "Song", artists: [],
                                     durationMS: 180000, trackNumber: 1, discNumber: 1, album: album("Playing")))
        model.playback = state
        await service.setPlayback(state)
        await service.holdPlaybackRead()
        let refresh = Task { await model.refreshPlayback() }
        try await waitUntil { await service.hasHeldPlayback() }
        await model.perform(.pause)
        XCTAssertEqual(model.playback?.isPlaying, false)
        await service.releasePlaybackRead()
        await refresh.value
        XCTAssertEqual(model.playback?.isPlaying, false, "A poll captured before pause must not restore the playing state")
    }

    func testLateToastAlbumLookupDoesNotReplaceNewerNavigation() async throws {
        let record = album("toast")
        let service = LibraryService([record], delay: .milliseconds(50))
        let model = AppModel(service: service)
        model.connection = .connected
        let state = PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: "track", name: "Song", artists: [],
                                    durationMS: 180000, trackNumber: 1, discNumber: 1, album: nil, albumID: record.albumID))
        let toast = try XCTUnwrap(TrackAnnouncement(state: state, album: nil, tracks: []))
        let opening = Task { await model.openAlbum(from: toast) }
        try await waitUntil { await service.albumRequestCount > 0 }
        let chosen = album("Chosen later")
        model.select(chosen)
        await opening.value
        XCTAssertEqual(model.selectedAlbum, chosen)
        XCTAssertNil(model.notice)
    }
    func testReopeningWindowDoesNotRestartSessionOrReplaceNavigation() async {
        let model = AppModel(demo: true)
        let first = await model.startIfNeeded()
        XCTAssertTrue(first)
        let browsing = album("Browsing")
        model.selectedAlbum = browsing
        model.isSearching = true; model.query = "Artist"; model.searchOffset = 240
        model.albums = [browsing]
        let reopened = await model.startIfNeeded()
        XCTAssertFalse(reopened)
        XCTAssertEqual(model.selectedAlbum, browsing)
        XCTAssertEqual(model.query, "Artist"); XCTAssertEqual(model.searchOffset, 240)
        XCTAssertEqual(model.albums, [browsing])
        model.setForeground(false)
    }
    func testTrackAnnouncementUsesPlayingAlbumAndLoadsDiscMetadataWithoutChangingBrowsing() async throws {
        let service = LibraryService([])
        let albumTracks = (1...13).map { number in
            AlbumTrack(spotifyID: "song-\(number)", name: "Song \(number)", artists: [], durationMS: 180000,
                       trackNumber: number <= 7 ? number : number - 7, discNumber: number <= 7 ? 1 : 2)
        }
        await service.setTracks(albumTracks)
        var announcements: [TrackAnnouncement] = []
        var dismissals = 0
        let controller = TrackAnnouncementController(wait: { delay in
            if delay == .seconds(1) { await Task.yield() }
            else { try await Task.sleep(for: delay) }
        }, present: { announcements.append($0) }, dismiss: { dismissals += 1 })
        let model = AppModel(service: service, trackAnnouncements: controller)
        model.connection = .connected
        model.selectedAlbum = album("Browsing")
        model.tracks = tracks(count: 1)
        let item = PlaybackTrack(id: "song-9", name: "Playing Song", artists: [], durationMS: 180000,
                                 trackNumber: 2, discNumber: 2, album: nil,
                                 albumID: AlbumID(rawValue: "Playing"), albumTotalTracks: 13)
        await service.setPlayback(PlaybackSnapshot(isPlaying: true, item: item))
        await model.refreshPlayback()
        try await waitUntil { announcements.last?.counter == "9/13" }
        XCTAssertEqual(announcements.last?.name, "Playing Song")
        XCTAssertEqual(model.selectedAlbum?.id, "Browsing")
        XCTAssertEqual(model.tracks.count, 1)
        await service.setPlayback(PlaybackSnapshot(isPlaying: false, item: item))
        await model.refreshPlayback()
        XCTAssertEqual(dismissals, 1)
        let count = announcements.count
        await service.setPlayback(PlaybackSnapshot(isPlaying: true, item: item))
        await model.refreshPlayback()
        await Task.yield()
        XCTAssertEqual(announcements.count, count, "Resuming the same song must not show another toast")
        controller.reset()
    }
    func testSuccessfulSaveUpdatesLibraryWithoutRefetchAndKeepsPaginationConsistent() async {
        let service = LibraryService([album("One"), album("Two"), album("Three")], pageSize: 2)
        let model = AppModel(service: service)
        model.connection = .connected
        await model.loadPage(offset: 0)
        XCTAssertEqual(model.nextOffset, 2)
        model.checkedSavedIDs.insert("New")
        await service.update([], failure: .http(503, "Temporary"))
        await model.toggleSaved(album("New"))
        XCTAssertEqual(model.albums.map(\.id), ["New", "One", "Two"])
        XCTAssertEqual(model.nextOffset, 3)
        XCTAssertTrue(model.savedIDs.contains("New"))
        XCTAssertNil(model.notice); XCTAssertNil(model.saveErrors["New"])
        await model.toggleSaved(album("One"))
        XCTAssertEqual(model.albums.map(\.id), ["New", "Two"])
        XCTAssertEqual(model.nextOffset, 2)
        let requests = await service.requestCount
        XCTAssertEqual(requests, 1, "Saving must not refetch the library or report an unrelated read failure")
    }
    func testExhaustedSaveFailureIsInlineAndRetryKeepsSameDesiredState() async {
        let service = LibraryService([album("Saved")])
        let model = AppModel(service: service)
        model.connection = .connected
        await model.loadPage(offset: 0)
        await service.configureSave(failure: .http(503, "Temporary"))
        await model.toggleSaved(album("Saved"))
        XCTAssertTrue(model.savedIDs.contains("Saved"), "Failure must not pretend the removal succeeded")
        XCTAssertNotNil(model.saveErrors["Saved"])
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isSaving); XCTAssertNil(model.savingAlbumID)
        await service.configureSave()
        await model.toggleSaved(album("Saved"))
        XCTAssertFalse(model.savedIDs.contains("Saved"))
        XCTAssertNil(model.saveErrors["Saved"])
        let saves = await service.saveRequests
        XCTAssertEqual(saves, [false, false])
    }
    func testSavingShowsPendingStateAndIgnoresRepeatedClicks() async throws {
        let service = LibraryService([])
        await service.configureSave(delay: .milliseconds(40))
        let model = AppModel(service: service)
        model.checkedSavedIDs.insert("New")
        let task = Task { await model.toggleSaved(album("New")) }
        try await waitUntil { await service.saveRequests.count == 1 }
        XCTAssertTrue(model.isSaving); XCTAssertEqual(model.savingAlbumID, "New")
        XCTAssertFalse(model.savedIDs.contains("New"))
        await model.toggleSaved(album("New"))
        await task.value
        XCTAssertTrue(model.savedIDs.contains("New")); XCTAssertFalse(model.isSaving)
        let saves = await service.saveRequests
        XCTAssertEqual(saves, [true])
    }
    func testFailedSavedStateCanBeRetriedWithoutLeavingButtonPermanentlyDisabled() async {
        let service = LibraryService([album("Saved")])
        let model = AppModel(service: service)
        await service.configureSavedCheck(failure: .http(503, "Temporary"))
        await model.checkSaved(album("Saved"))
        XCTAssertFalse(model.checkedSavedIDs.contains("Saved"))
        XCTAssertTrue(model.checkingSavedIDs.isEmpty)
        XCTAssertNotNil(model.saveErrors["Saved"]); XCTAssertNil(model.notice)
        await service.configureSavedCheck(failure: nil)
        await model.checkSaved(album("Saved"))
        XCTAssertTrue(model.checkedSavedIDs.contains("Saved")); XCTAssertTrue(model.savedIDs.contains("Saved"))
        XCTAssertNil(model.saveErrors["Saved"])
    }
    func testBackgroundFailurePreservesLastPlaybackWithoutRepeatedBanners() async {
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        model.playback = PlaybackSnapshot(isPlaying: true, context: PlaybackContext(type: "album", uri: album("Current").albumID.uri))
        await service.configurePlayback(failure: .http(503, "Temporary"))
        await model.refreshPlayback()
        await model.refreshPlayback()
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.playingAlbumID, album("Current").albumID)
        await service.configurePlayback(failure: .signedOut)
        await model.refreshPlayback()
        XCTAssertEqual(model.connection, .disconnected)
        XCTAssertNotNil(model.notice, "Authorization problems still require a visible action")
    }
    func testLateLibraryRefreshCannotUndoSuccessfulSave() async throws {
        let service = LibraryService([album("Old")], delay: .milliseconds(40))
        let model = AppModel(service: service)
        model.connection = .connected
        await model.loadPage(offset: 0)
        model.checkedSavedIDs.insert("New")
        let refresh = Task { await model.refreshCollection() }
        try await waitUntil { await service.requestCount == 2 }
        await model.toggleSaved(album("New"))
        await refresh.value
        XCTAssertEqual(model.albums.map(\.id), ["New", "Old"])
        XCTAssertTrue(model.savedIDs.contains("New"))
        XCTAssertFalse(model.isLoading)
    }
    func testHoverDurationReusesTracksWithoutChangingSelectionOrPlayback() async {
        let record = album("Hover")
        let current = album("Current")
        let service = LibraryService([record, current])
        let expectedTracks = tracks()
        await service.setTracks(expectedTracks)
        let model = AppModel(service: service)
        model.selectedAlbum = current
        model.tracks = [expectedTracks[0]]
        model.playback = PlaybackSnapshot(isPlaying: true,
                                         context: PlaybackContext(type: "album", uri: current.albumID.uri))

        let first = await model.albumDuration(for: record)
        let second = await model.albumDuration(for: record)
        XCTAssertEqual(first, 55_000)
        XCTAssertEqual(second, first)
        XCTAssertEqual(model.selectedAlbum, current)
        XCTAssertEqual(model.tracks, [expectedTracks[0]])
        XCTAssertFalse(model.isLoadingTracks)
        XCTAssertEqual(model.playingAlbumID, current.albumID)
        XCTAssertEqual(model.playback?.isPlaying, true)
        XCTAssertNil(model.notice)
        let plays = await service.playedOn
        let commands = await service.commandCount
        XCTAssertTrue(plays.isEmpty)
        XCTAssertEqual(commands, 0)

        model.selectedAlbum = record
        await model.loadTracks(record)
        XCTAssertEqual(model.tracks, expectedTracks, "Opening the album reuses the hover's complete track cache")
        let requests = await service.trackRequestCount
        XCTAssertEqual(requests, 1)
    }
    func testHoverDurationDoesNotDisplayPartialTotalsOrRaiseErrorBanners() async {
        let record = album("Hover")
        let service = LibraryService([record])
        let model = AppModel(service: service)
        await service.setTracks(tracks(count: 9))
        let partial = await model.albumDuration(for: record)
        XCTAssertNil(partial)
        await service.setTracks([], failure: .invalidResponse)
        let failed = await model.albumDuration(for: record)
        XCTAssertNil(failed)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.tracksFailed)
        await service.setTracks(tracks())
        let recovered = await model.albumDuration(for: record)
        XCTAssertEqual(recovered, 55_000)
        let requests = await service.trackRequestCount
        XCTAssertEqual(requests, 3, "Incomplete and failed responses must not poison the shared track cache")
    }
    func testCancelledHoverDiscardsLateMetadata() async throws {
        let record = album("Hover")
        let service = LibraryService([record])
        await service.setTracks(tracks(), delay: .seconds(1))
        let model = AppModel(service: service)
        let request = Task { await model.albumDuration(for: record) }
        try await waitUntil { await service.trackRequestCount == 1 }
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        XCTAssertNil(model.selectedAlbum)
        XCTAssertTrue(model.tracks.isEmpty)
        await service.setTracks(tracks())
        let next = await model.albumDuration(for: record)
        XCTAssertEqual(next, 55_000)
        let requests = await service.trackRequestCount
        XCTAssertEqual(requests, 2, "A cancelled preview must not store its late result")
    }
    func testSelectingAnotherAlbumPreservesPlaybackWithoutSendingCommands() async throws {
        let current = album("Current")
        let browsing = album("Browsing")
        let service = LibraryService([current, browsing])
        let model = AppModel(service: service)
        model.connection = .connected
        model.albums = [current, browsing]
        model.playback = PlaybackSnapshot(isPlaying: true,
                                         context: PlaybackContext(type: "album", uri: current.albumID.uri))

        model.select(browsing)
        try await waitUntil { model.checkedSavedIDs.contains(browsing.id) }

        XCTAssertEqual(model.selectedAlbum, browsing)
        XCTAssertEqual(model.playingAlbumID, current.albumID)
        XCTAssertEqual(model.playback?.isPlaying, true)
        let plays = await service.playedOn
        let transfers = await service.transfers
        let commands = await service.commandCount
        XCTAssertTrue(plays.isEmpty, "Presenting an album must not start it")
        XCTAssertTrue(transfers.isEmpty, "Presenting an album must not transfer playback")
        XCTAssertEqual(commands, 0, "Presenting an album must not pause or change the current track")
    }
    func testCurrentAlbumResolvesPartialPlaybackFromLibraryAndClearsWhenPlaybackEnds() throws {
        let current = album("Current")
        let model = AppModel(service: LibraryService([]))
        model.albums = [current, album("Browsing")]
        model.selectedAlbum = album("Browsing")
        model.playback = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"item":{"id":"song","name":"Song","duration_ms":180000,
          "album":{"id":"Current"}},"context":{"type":"playlist","uri":"spotify:playlist:list1"}}
        """.utf8))
        XCTAssertTrue(model.hasPlayback)
        XCTAssertEqual(model.playingAlbumID, current.albumID)
        XCTAssertEqual(model.playingAlbum, current)
        model.playback?.isPlaying = false
        XCTAssertEqual(model.playingAlbum, current, "Pausing must keep the album identified")
        model.playback = nil
        XCTAssertNil(model.playingAlbumID)
        XCTAssertNil(model.playingAlbum, "Browsing an album must not imply it is playing")
    }
    func testCurrentAlbumUsesAlbumContextAndRejectsUnrelatedQueuedTrack() async throws {
        let current = album("Current")
        let service = LibraryService([])
        let model = AppModel(service: service)
        model.connection = .connected
        model.albums = [current]
        model.playback = PlaybackSnapshot(isPlaying: true, context: PlaybackContext(type: "album", uri: current.albumID.uri))
        XCTAssertEqual(model.playingAlbum, current)
        let external = album("External")
        model.playback?.item = PlaybackTrack(id: "song", name: "Song", artists: [], durationMS: 180000,
                                             trackNumber: 1, discNumber: 1, album: external)
        await service.setTracks(tracks())
        await service.setPlayback(model.playback)
        await model.refreshPlayback()
        try await waitUntil { model.playingAlbum == external }
        XCTAssertEqual(model.playingAlbum, external, "An unrelated queued song must not inherit the old album context")
        model.playback = PlaybackSnapshot(isPlaying: true, context: PlaybackContext(type: "playlist", uri: "spotify:playlist:list1"))
        XCTAssertNil(model.playingAlbum)
    }
    func testDockUsesConfirmedAlbumCoverAndUpdatesWhenLibraryArrives() async throws {
        let coverURL = URL(string: "https://example.test/current.jpg")!
        let current = album("Current", artwork: coverURL)
        let browsing = album("Browsing", artwork: URL(string: "https://example.test/browsing.jpg")!)
        let service = LibraryService([current])
        var usedURLs: [URL] = []
        let dock = DockArtworkController(originalIcon: { nil }, cachedImage: { url in
            usedURLs.append(url)
            return NSImage(size: NSSize(width: 4, height: 4))
        }, loadImage: { _ in nil }, applyImage: { _ in })
        let model = AppModel(service: service, dockArtwork: dock)
        model.connection = .connected
        model.selectedAlbum = browsing
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"item":{"name":"Song","duration_ms":180000,"album":{"id":"Current"}}}
        """.utf8))
        await service.setPlayback(state)
        await model.refreshPlayback()
        XCTAssertFalse(usedURLs.contains(browsing.artwork!), "Browsing another album must not put its artwork in the Dock")
        await model.loadPage(offset: 0)
        XCTAssertEqual(usedURLs, [coverURL], "New library metadata should repair the Dock without waiting for another poll")
        XCTAssertEqual(model.playingArtworkURL, coverURL)
        model.playback?.isPlaying = false
        XCTAssertEqual(model.playingArtworkURL, coverURL)
        model.playback = nil
        XCTAssertNil(model.playingArtworkURL)
    }
    func testStartupSelectsActiveControllableDeviceWithoutTransferring() async {
        let service = LibraryService([])
        await service.setDevices([device(nil), device("restricted", active: true, restricted: true),
                                  device("mac"), device("speaker", type: "speaker", active: true)])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.preferredDevice?.id, "speaker")
        let transfers = await service.transfers
        XCTAssertTrue(transfers.isEmpty, "Discovering a default must not move or start music")
    }
    func testIdleClientDefaultsToComputerAndStartsAlbumOnFirstClick() async {
        let record = album("First")
        let service = LibraryService([record])
        await service.setDevices([device("speaker", type: "speaker"), device("mac")])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertNil(model.playback)
        XCTAssertEqual(model.preferredDevice?.id, "mac")
        await model.play(record)
        let playedOn = await service.playedOn
        XCTAssertEqual(playedOn, ["mac"])
        XCTAssertTrue(model.playback?.isPlaying == true)
        XCTAssertNil(model.notice)
    }
    func testFirstPlayWaitsForDeviceDiscoveryAlreadyInProgress() async throws {
        let record = album("First")
        let service = LibraryService([record])
        await service.setDevices([device("mac")])
        await service.delayDevices(.milliseconds(100))
        let model = AppModel(service: service)
        model.connection = .connected
        let discovery = Task { await model.refreshDevices() }
        try await waitUntil { await service.deviceRequestCount == 1 }
        await model.play(record)
        await discovery.value
        let requests = await service.deviceRequestCount
        let playedOn = await service.playedOn
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(playedOn, ["mac"])
        XCTAssertNil(model.notice)
    }
    func testRefreshRetainsSelectionAndFallsBackWhenDeviceGoesOffline() async {
        let service = LibraryService([])
        await service.setDevices([device("mac"), device("speaker", type: "speaker")])
        let model = AppModel(service: service)
        model.connection = .connected
        await model.refreshDevices()
        await model.chooseDevice(device("speaker", type: "speaker"))
        await model.refreshDevices()
        XCTAssertEqual(model.preferredDevice?.id, "speaker")
        await service.setDevices([device("mac"), device("speaker", type: "speaker", restricted: true)])
        await model.refreshDevices()
        XCTAssertEqual(model.preferredDevice?.id, "mac")
        await service.setDevices([device("phone", type: "smartphone")])
        await model.refreshDevices()
        XCTAssertEqual(model.preferredDevice?.id, "phone")
        await service.setDevices([device(nil), device("", active: true), device("restricted", restricted: true)])
        await model.refreshDevices()
        XCTAssertNil(model.preferredDevice)
        await model.play(album("Unavailable"))
        let playedOn = await service.playedOn
        XCTAssertTrue(playedOn.isEmpty)
        XCTAssertNotNil(model.notice)
    }
    func testManualDeviceChoiceSurvivesRestartAndIsScopedToAccount() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root, dataRoot: root.appendingPathComponent("data"))
        let service = LibraryService([])
        await service.setDevices([device("mac"), device("speaker", type: "speaker")])
        let model = AppModel(service: service, localStore: store, cacheAccount: "one")
        model.setForeground(false)
        await model.finishConnection()
        await model.chooseDevice(device("speaker", type: "speaker"))
        let restarted = AppModel(service: service, localStore: store, cacheAccount: "one")
        restarted.setForeground(false)
        await restarted.finishConnection()
        XCTAssertEqual(restarted.preferredDevice?.id, "speaker")
        let other = AppModel(service: service, localStore: store, cacheAccount: "two")
        other.setForeground(false)
        await other.finishConnection()
        XCTAssertEqual(other.preferredDevice?.id, "mac")
    }
    func testPlaybackPollingFollowsExternalDeviceSwitch() async {
        let service = LibraryService([])
        await service.setDevices([device("mac"), device("speaker", type: "speaker")])
        let model = AppModel(service: service)
        model.connection = .connected
        await model.refreshDevices()
        XCTAssertEqual(model.preferredDevice?.id, "mac")
        await service.setPlayback(PlaybackSnapshot(device: device("speaker", type: "speaker", active: true)))
        await model.refreshPlayback()
        XCTAssertEqual(model.preferredDevice?.id, "speaker")
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Model did not reach the expected state")
    }
    func testSuccessfulAuthorizationEndsBeforeSheetDismissalAndLibraryLoad() async throws {
        let service = LibraryService([album("Lonerism")], delay: .milliseconds(100))
        let model = AppModel(service: service)
        model.setForeground(false)
        model.isAuthorizing = true; model.showSettings = true
        let task = Task { await model.finishConnection() }
        try await waitUntil { await service.requestCount == 1 }
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.isAuthorizing, "Sheet disappearance must not treat library loading as unfinished authorization")
        XCTAssertFalse(model.showSettings)
        await task.value
        XCTAssertTrue(model.hasLoadedPage)
        XCTAssertEqual(model.albums.map(\.name), ["Lonerism"])
    }
    func testFailedInitialSyncIsNotAnEmptyLibraryAndCanRetry() async {
        let service = LibraryService([])
        await service.update([], failure: .http(503, "暂时不可用"))
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertFalse(model.hasLoadedPage)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.notice)

        await service.update([album("The Bends")])
        await model.retry()
        XCTAssertTrue(model.hasLoadedPage)
        XCTAssertEqual(model.albums.map(\.name), ["The Bends"])
        XCTAssertNil(model.notice)
    }
    func testReturningToCollectionKeepsWarmCacheAndManualRefreshSyncs() async throws {
        let service = LibraryService([album("Old")])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        await service.update([album("New")])
        model.showCollection()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.albums.map(\.name), ["Old"])
        let requests = await service.requestCount
        XCTAssertEqual(requests, 1)
        await model.refreshCollection()
        XCTAssertEqual(model.savedIDs, ["New"])
        XCTAssertEqual(model.checkedSavedIDs, ["New"])
    }
    func testReturningFromSpotifyDoesNotRefetchFreshLibrary() async throws {
        let service = LibraryService([album("Old")])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        await service.update([album("New")])
        model.setForeground(true)
        try await Task.sleep(for: .milliseconds(30))
        model.setForeground(false)
        XCTAssertEqual(model.albums.map(\.name), ["Old"])
        let requests = await service.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.hasLoadedPage)
    }

    func testInfiniteScrollAppendsOnceAndRefreshPreservesLoadedExtent() async {
        let service = LibraryService([album("A"), album("B"), album("C"), album("D")], delay: .milliseconds(20), pageSize: 2)
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B"])
        async let first: Void = model.loadMoreAlbums()
        async let duplicate: Void = model.loadMoreAlbums()
        _ = await (first, duplicate)
        XCTAssertEqual(model.albums.map(\.id), ["A", "B", "C", "D"])
        XCTAssertNil(model.nextOffset)
        let requests = await service.requestCount
        XCTAssertEqual(requests, 2)
        await service.update([album("New"), album("A"), album("C"), album("D")])
        await model.refreshCollection()
        XCTAssertEqual(model.albums.map(\.id), ["New", "A", "C", "D"])
    }

    func testOfflineRestartRestoresAccountCacheWithoutShowingEmptyLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root, dataRoot: root.appendingPathComponent("data"))
        await store.saveLibrary(CachedLibrary(albums: [album("Cached")], nextOffset: 20, updatedAt: .distantPast), account: "one", generation: await store.generation())
        let service = LibraryService([])
        await service.update([], failure: .http(503, "Offline"))
        let model = AppModel(service: service, localStore: store, cacheAccount: "one")
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.name), ["Cached"])
        XCTAssertEqual(model.nextOffset, 20)
        XCTAssertTrue(model.hasLoadedPage)
        let other = AppModel(service: service, localStore: store, cacheAccount: "two")
        other.setForeground(false)
        await other.finishConnection()
        XCTAssertTrue(other.albums.isEmpty)
        XCTAssertFalse(other.hasLoadedPage)
    }

    func testArrangementLoadsEntireCollectionWithoutChangingLibraryOrder() async {
        let service = LibraryService([album("A"), album("B"), album("C"), album("D"), album("E")], pageSize: 2)
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B"])
        await model.loadRemainingCollection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B", "C", "D", "E"])
        XCTAssertNil(model.nextOffset)
        await model.loadRemainingCollection()
        let requests = await service.requestCount
        XCTAssertEqual(requests, 3)
    }

    func testYearOrderingKeepsUnknownYearsLastAndTiesStable() {
        func record(_ id: String, _ date: String) -> Album {
            Album(id: id, name: id, artists: [], albumType: "album", images: [], releaseDate: date, totalTracks: 10)
        }
        let albums = [record("first", "2007-10-10"), record("unknown", ""), record("old", "1973"), record("second", "2007"), record("new", "2024-05")]
        XCTAssertEqual(AlbumSortOrder.oldestFirst.arrange(albums).map(\.id), ["old", "first", "second", "new", "unknown"])
        XCTAssertEqual(AlbumSortOrder.newestFirst.arrange(albums).map(\.id), ["new", "first", "second", "old", "unknown"])
        XCTAssertEqual(AlbumSortOrder.library.arrange(albums).map(\.id), albums.map(\.id))
        XCTAssertNil(record("invalid", "0000").releaseYear)
    }

    func testArtistGroupingCombinesPrimaryArtistAndOrdersAlbumsByYear() {
        func record(_ id: String, _ artist: String, _ year: String) -> Album {
            Album(id: id, name: id, artists: [Artist(name: artist), Artist(name: "Guest")], albumType: "album", images: [], releaseDate: year, totalTracks: 10)
        }
        let albums = [record("rainbows", "Radiohead", "2007"), record("ram", "Daft Punk", "2013"), record("bends", "radiohead", "1995")]
        let groups = AlbumArtistGroup.make(from: albums, grouped: true, order: .oldestFirst)
        XCTAssertEqual(groups.map(\.id), ["daft punk", "radiohead"])
        XCTAssertEqual(groups.last?.albums.map(\.id), ["bends", "rainbows"])
        XCTAssertEqual(groups.flatMap(\.albums).count, albums.count)
        let ungrouped = AlbumArtistGroup.make(from: albums, grouped: false, order: .newestFirst)
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertNil(ungrouped.first?.name)
        XCTAssertEqual(ungrouped.first?.albums.map(\.id), ["ram", "rainbows", "bends"])
    }
}
