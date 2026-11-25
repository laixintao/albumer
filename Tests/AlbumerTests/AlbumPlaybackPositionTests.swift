import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class AlbumPlaybackPositionTests: XCTestCase {
    private let tracks = [
        AlbumTrack(spotifyID: "one", name: "One", artists: [], durationMS: 180000, trackNumber: 1, discNumber: 1),
        AlbumTrack(spotifyID: "two", name: "Two", artists: [], durationMS: 180000, trackNumber: 2, discNumber: 1),
        AlbumTrack(spotifyID: "three", name: "Three", artists: [], durationMS: 180000, trackNumber: 1, discNumber: 2,
                   linkedFrom: SpotifyTrackReference(id: "original-three"))
    ]

    func testResumeUsesTrackIdentityAcrossDiscsAndRelinking() {
        let position = AlbumPlaybackPosition(trackID: "original-three", linkedFromID: nil, discNumber: 2, trackNumber: 1, positionMS: 42000)
        XCTAssertEqual(position.start(in: tracks), AlbumPlaybackStart(trackIndex: 2, positionMS: 42000))
        XCTAssertEqual(position.start(in: Array(tracks.reversed())), AlbumPlaybackStart(trackIndex: 0, positionMS: 42000))
    }

    func testRemovedTrackDoesNotGuessFromOldTrackNumber() {
        let position = AlbumPlaybackPosition(trackID: "removed", linkedFromID: nil, discNumber: 1, trackNumber: 1, positionMS: 42000)
        XCTAssertNil(position.start(in: tracks))
        XCTAssertNil(position.start(in: []))
    }

    func testCompletedTrackAdvancesAndCompletedAlbumStartsOver() {
        let middle = AlbumPlaybackPosition(trackID: "two", linkedFromID: nil, discNumber: 1, trackNumber: 2, positionMS: 180000)
        let end = AlbumPlaybackPosition(trackID: "three", linkedFromID: nil, discNumber: 2, trackNumber: 1, positionMS: 181000)
        XCTAssertEqual(middle.start(in: tracks), AlbumPlaybackStart(trackIndex: 2, positionMS: 0))
        XCTAssertEqual(end.start(in: tracks), .beginning)
    }

    func testDuplicateTrackIDsRequireAnUnambiguousDiscAndTrackNumber() {
        let duplicate = AlbumTrack(spotifyID: "one", name: "One", artists: [], durationMS: 180000, trackNumber: 2, discNumber: 2)
        let position = AlbumPlaybackPosition(trackID: "one", linkedFromID: nil, discNumber: 2, trackNumber: 2, positionMS: 15000)
        XCTAssertEqual(position.start(in: tracks + [duplicate]), AlbumPlaybackStart(trackIndex: 3, positionMS: 15000))
        let ambiguous = AlbumPlaybackPosition(trackID: "one", linkedFromID: nil, discNumber: nil, trackNumber: nil, positionMS: 15000)
        XCTAssertNil(ambiguous.start(in: tracks + [duplicate]))
    }
}
