import SwiftUI

/// View-local presentation state: choosing a record must never send a playback command.
struct AlbumInsertion: Identifiable {
    static let coordinateSpace = "albumInsertion"
    let id = UUID()
    let album: Album
    let source: CGRect
}

struct AlbumArtworkDestination {
    let albumID: String
    let bounds: Anchor<CGRect>
}

struct AlbumArtworkDestinationKey: PreferenceKey {
    static var defaultValue: AlbumArtworkDestination? { nil }
    static func reduce(value: inout AlbumArtworkDestination?, nextValue: () -> AlbumArtworkDestination?) {
        value = nextValue() ?? value
    }
}

struct AlbumReturnDestinationKey: PreferenceKey {
    static var defaultValue: [String: [Anchor<CGRect>]] { [:] }
    static func reduce(value: inout [String: [Anchor<CGRect>]], nextValue: () -> [String: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

private struct ReturningAlbumKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var returningAlbumID: String? {
        get { self[ReturningAlbumKey.self] }
        set { self[ReturningAlbumKey.self] = newValue }
    }
}

/// Give restored scroll positions a moment to settle, then return the cover to its card.
struct AlbumReturnOverlay: View {
    let returning: AlbumInsertion
    let destination: CGRect?
    let completion: () -> Void
    @State private var target: CGRect?

    var body: some View {
        let frame = target ?? returning.source
        AlbumArtwork(album: returning.album)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .task(id: destination) {
                guard let destination else {
                    do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation() }
                    catch { return }
                    completion()
                    return
                }
                if target != nil { completion(); return }
                do { try await Task.sleep(for: .milliseconds(80)); try Task.checkCancellation() }
                catch { return }
                withAnimation(.smooth(duration: 0.32, extraBounce: 0), completionCriteria: .removed) {
                    target = destination
                } completion: { completion() }
            }
    }
}

/// Navigation moves the unmodified image between layout positions.
struct AlbumInsertionOverlay: View {
    let insertion: AlbumInsertion
    let destination: CGRect
    let completion: () -> Void
    @State private var arrived = false

    var body: some View {
        let frame = arrived ? destination : insertion.source
        AlbumArtwork(album: insertion.album)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                withAnimation(.smooth(duration: 0.32, extraBounce: 0), completionCriteria: .removed) {
                    arrived = true
                } completion: { completion() }
            }
            .onChange(of: destination) { _, _ in completion() }
    }
}

struct PlaybackIndicator: View {
    var playing: Bool
    var body: some View {
        Image(systemName: playing ? "speaker.wave.2.fill" : "pause.fill")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }
}
