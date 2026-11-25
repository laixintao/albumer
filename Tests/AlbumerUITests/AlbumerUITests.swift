import XCTest
import AppKit

@MainActor
final class AlbumerUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo", "--window-size=1120x800"]
        app.launch()
        let loaded = app.buttons["album-preview-01"].waitForExistence(timeout: 10)
        XCTAssertTrue(loaded)
    }
    override func tearDown() async throws { app.terminate() }
    private func capture(_ name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func enterSearch(_ text: String, into field: XCUIElement) {
        // Paste a complete query so the user's active CJK input method does not
        // consume spaces as candidate-selection keystrokes. Restore their clipboard.
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        defer {
            board.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        app.activate(); field.click(); field.typeKey("a", modifierFlags: .command)
        board.clearContents(); board.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        field.typeKey(.return, modifierFlags: [])
    }
    func testCollectionStageAndTransport() {
        XCTAssertFalse(app.staticTexts["albumer"].exists)
        XCTAssertFalse(app.buttons["playPause"].exists, "The collection must not contain a separate player")
        XCTAssertFalse(app.sliders["playbackProgress"].exists)
        XCTAssertFalse(app.buttons["下一页"].exists)
        capture("01-collection")
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["collectionButton"].exists, "Album details need only one back button")
        XCTAssertFalse(app.toolbars.buttons["saveAlbum"].exists)
        XCTAssertTrue(app.scrollViews["albumDetails"].buttons["saveAlbum"].exists)
        XCTAssertTrue(app.staticTexts["Paper Horizons"].exists)
        let lastTrack = app.buttons["track-preview-01-10"]
        XCTAssertTrue(lastTrack.waitForExistence(timeout: 3))
        XCTAssertTrue(app.scrollViews["albumTracks"].frame.contains(lastTrack.frame), "A ten-track album should fit without scrolling at the default window size")
        XCTAssertEqual(app.buttons["backToCollection"].frame.midY, app.buttons["searchButton"].frame.midY, accuracy: 1)
        let play = app.buttons["playPause"]
        XCTAssertTrue(app.scrollViews["albumDetails"].frame.contains(play.frame), "Playback belongs with the album details")
        XCTAssertLessThan(play.frame.midY, app.windows.firstMatch.frame.minY + app.windows.firstMatch.frame.height * 0.6)
        app.buttons["playPause"].click()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 4))
        capture("02-stage")
        app.buttons["下一首"].click()
        let playingTrack = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "track-preview-01-2", "正在播放")).firstMatch
        XCTAssertTrue(playingTrack.waitForExistence(timeout: 4))
        XCTAssertTrue(app.scrollViews["albumTracks"].exists)
        XCTAssertTrue(app.buttons["track-preview-01-2"].isEnabled)
        app.buttons["backToCollection"].click()
        XCTAssertTrue(app.buttons["album-preview-01"].exists)
        XCTAssertFalse(app.buttons["playPause"].exists)
        let currentAlbum = app.buttons["currentAlbum"]
        XCTAssertTrue(currentAlbum.waitForExistence(timeout: 3))
        XCTAssertTrue(currentAlbum.label.contains("Paper Horizons"))
        XCTAssertTrue(currentAlbum.label.contains("正在播放"))
        XCTAssertTrue(app.buttons["album-preview-01"].label.contains("正在播放"))
        currentAlbum.click()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 3), "Opening the current album must preserve playback")
    }
    func testAlbumSearchAndEmptyState() {
        app.buttons["searchButton"].click()
        let field = app.textFields["albumSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterSearch("Lumen Assembly", into: field)
        XCTAssertTrue(app.buttons["album-preview-01"].waitForExistence(timeout: 5))
        capture("03-search")
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["collectionButton"].exists)
        app.buttons["backToCollection"].click()
        XCTAssertEqual(field.value as? String, "Lumen Assembly", "Back should preserve the search that opened the album")
        enterSearch("North Window", into: field)
        XCTAssertEqual(field.value as? String, "North Window")
        XCTAssertTrue(app.buttons["album-preview-06"].waitForExistence(timeout: 5))
        enterSearch("zzzznotarecord", into: field)
        XCTAssertTrue(app.staticTexts["没有找到专辑"].waitForExistence(timeout: 5))
        capture("04-empty")
    }
    func testTrackSelectionAndAlbumResume() {
        app.buttons["album-preview-01"].click()
        let selected = app.buttons["track-preview-01-5"]
        XCTAssertTrue(selected.waitForExistence(timeout: 3))
        selected.click()
        let playing = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "track-preview-01-5", "正在播放")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        app.buttons["backToCollection"].click()
        app.buttons["album-preview-02"].click()
        app.buttons["playPause"].click()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        app.buttons["backToCollection"].click()
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.staticTexts["albumResumeInfo"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["playPause"].label, "继续播放")
        capture("track-resume")
        app.buttons["playPause"].click()
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        app.buttons["track-preview-01-1"].click()
        let first = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "track-preview-01-1", "正在播放")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }
    func testAlbumTimelineAndThreeDiscIndicators() {
        app.terminate()
        app.launchArguments = ["--demo", "--three-discs", "--window-size=1120x800"]
        app.launch()
        XCTAssertTrue(app.buttons["album-preview-01"].waitForExistence(timeout: 5))
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.sliders["playbackProgress"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["albumTotalTime"].value as? String, "38:45")
        for disc in 1...3 {
            XCTAssertTrue(app.descendants(matching: .any)["albumDiscDot-\(disc)"].exists)
        }
        XCTAssertFalse(app.descendants(matching: .any)["albumDiscDot-4"].exists)
        app.buttons["track-preview-01-5"].click()
        let secondDisc = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "albumDiscDot-2", "当前")).firstMatch
        XCTAssertTrue(secondDisc.waitForExistence(timeout: 5))
        // The first four tracks total 13:42. Changing tracks must not reset album elapsed time.
        let elapsed = app.staticTexts["albumElapsedTime"].value as? String ?? ""
        XCTAssertTrue(elapsed.hasPrefix("13:"))
        XCTAssertEqual(app.staticTexts["albumTotalTime"].value as? String, "38:45")
        capture("album-timeline-three-discs")
    }
    func testSettingsAndDevices() {
        app.buttons["refreshCollection"].click()
        XCTAssertTrue(app.buttons["album-preview-01"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        XCTAssertFalse(app.buttons["devicesButton"].exists)
        app.activate()
        app.menuBars.menuBarItems["Albumer"].click()
        app.menuItems["设置…"].click()
        XCTAssertTrue(app.textFields["clientIDField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:8888/callback"].exists)
        capture("05-settings")
        app.buttons["关闭设置"].click()
        XCTAssertTrue(app.buttons["openSpotify"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["openSpotify"].label.contains("通过 Spotify 播放"))
        XCTAssertFalse(app.staticTexts["播放设备"].exists)
        XCTAssertFalse(app.staticTexts["打开 Spotify"].exists)
        XCTAssertEqual(app.buttons["device-preview-mac"].value as? String, "已选中")
        capture("06-devices")
    }
    func testCompactWindowAndKeyboardPlayback() {
        app.terminate()
        app.launchArguments = ["--demo", "--window-size=820x640"]
        app.launch()
        XCTAssertTrue(app.buttons["album-preview-01"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(window.frame.width, 825)
        capture("07-compact-collection")
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        let play = app.buttons["playPause"]
        XCTAssertTrue(window.frame.contains(play.frame))
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(app.buttons["device-preview-mac"].isHittable)
        XCTAssertTrue(window.frame.contains(app.buttons["device-preview-mac"].frame))
        capture("08-compact-stage")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 4))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["album-preview-01"].waitForExistence(timeout: 3))
    }
    func testReducedMotionMissingArtworkAndLongMetadata() {
        app.terminate()
        app.launchArguments = ["--demo", "--reduce-motion", "--edge-cases", "--window-size=820x640"]
        app.launch()
        let album = app.buttons["album-missing-cover"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["playPause"].isHittable)
        capture("09-reduced-motion-edge-cases")
    }
    func testStartingDifferentAlbumAndDeviceSwitch() {
        app.buttons["album-preview-02"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        app.buttons["playPause"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "track-preview-02-1", "正在播放")).firstMatch.waitForExistence(timeout: 5))
        let speaker = app.buttons["device-preview-speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 3))
        speaker.click()
        let selected = NSPredicate(format: "value == %@", "已选中")
        expectation(for: selected, evaluatedWith: speaker)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["device-preview-mac"].value as? String, "未选中")
        capture("10-album-device-switch")
    }
    func testIdleDeviceIsSelectedAndFirstPlayNeedsNoPicker() {
        app.terminate()
        app.launchArguments = ["--demo", "--idle-device", "--window-size=1120x800"]
        app.launch()
        let computer = app.buttons["device-preview-mac"]
        XCTAssertTrue(computer.waitForExistence(timeout: 5))
        XCTAssertEqual(computer.value as? String, "已选中")
        app.buttons["album-preview-01"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        XCTAssertEqual(computer.value as? String, "已选中")
        app.buttons["playPause"].click()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.popovers.count, 0)
        capture("12-idle-device-first-play")
    }
    func testCoverOnlyInfiniteScrollingAndReturnPosition() {
        app.terminate()
        app.launchArguments = ["--demo", "--many-albums", "--window-size=1120x800"]
        app.launch()
        app.activate()
        app.buttons["collectionButton"].click()
        let collection = app.scrollViews["albumCollection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        let last = app.buttons["album-preview-extra-59"]
        for _ in 0..<18 {
            if last.exists && last.isHittable { break }
            collection.swipeUp()
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertFalse(app.buttons["下一页"].exists)
        capture("11-infinite-collection")
        last.click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        app.buttons["backToCollection"].click()
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        XCTAssertTrue(last.isHittable)
    }
}
