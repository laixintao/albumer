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
        let loaded = app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].waitForExistence(timeout: 10)
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
        XCTAssertFalse(app.staticTexts["In Rainbows"].exists)
        XCTAssertFalse(app.buttons["下一页"].exists)
        capture("01-collection")
        app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["In Rainbows"].exists)
        app.buttons["playPause"].click()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 4))
        capture("02-stage")
        app.buttons["下一首"].click()
        let playingTrack = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "track-5vkqYmiPBYLaalcmjujWxK-2", "正在播放")).firstMatch
        XCTAssertTrue(playingTrack.waitForExistence(timeout: 4))
        XCTAssertTrue(app.scrollViews["albumTracks"].exists)
        XCTAssertFalse(app.buttons["Bodysnatchers"].exists)
        app.buttons["backToCollection"].click()
        XCTAssertTrue(app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].exists)
    }
    func testAlbumSearchAndEmptyState() {
        app.buttons["searchButton"].click()
        let field = app.textFields["albumSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterSearch("Radiohead", into: field)
        XCTAssertTrue(app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].waitForExistence(timeout: 5))
        capture("03-search")
        enterSearch("A Moon", into: field)
        XCTAssertEqual(field.value as? String, "A Moon")
        XCTAssertTrue(app.buttons["album-2ix8vWvvSp2Yo7rKMiWpkg"].waitForExistence(timeout: 5))
        enterSearch("zzzznotarecord", into: field)
        XCTAssertTrue(app.staticTexts["没有找到专辑"].waitForExistence(timeout: 5))
        capture("04-empty")
    }
    func testSettingsAndDevices() {
        app.buttons["refreshCollection"].click()
        XCTAssertTrue(app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].waitForExistence(timeout: 3))
        app.buttons["settingsButton"].click()
        XCTAssertTrue(app.textFields["clientIDField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:8888/callback"].exists)
        capture("05-settings")
        app.buttons["关闭设置"].click()
        app.buttons["devicesButton"].click()
        XCTAssertTrue(app.staticTexts["播放设备"].waitForExistence(timeout: 3))
        capture("06-devices")
    }
    func testCompactWindowAndKeyboardPlayback() {
        app.terminate()
        app.launchArguments = ["--demo", "--window-size=820x640"]
        app.launch()
        XCTAssertTrue(app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(window.frame.width, 825)
        capture("07-compact-collection")
        app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        let play = app.buttons["playPause"]
        XCTAssertTrue(window.frame.contains(play.frame))
        XCTAssertTrue(play.isHittable)
        capture("08-compact-stage")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 4))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["album-5vkqYmiPBYLaalcmjujWxK"].waitForExistence(timeout: 3))
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
        app.buttons["album-4m2880jivSbbyEGAKfITCa"].click()
        XCTAssertTrue(app.buttons["backToCollection"].waitForExistence(timeout: 3))
        app.buttons["playPause"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "track-4m2880jivSbbyEGAKfITCa-1", "正在播放")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["devicesButton"].click()
        let speaker = app.buttons["device-preview-speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 3))
        speaker.click()
        XCTAssertTrue(app.buttons["客厅"].waitForExistence(timeout: 5))
        capture("10-album-device-switch")
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
