import SwiftUI

/// Resolve visibility from the interpolated angle, so neither face becomes mirrored during a turn.
struct AlbumCardFace: AnimatableModifier {
    nonisolated var angle: Double
    let back: Bool
    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        let showsBack = normalized >= 90 && normalized < 270
        content
            .opacity(showsBack == back ? 1 : 0)
            .rotation3DEffect(.degrees(angle + (back ? 180 : 0)), axis: (x: 0, y: 1, z: 0), perspective: 0.08)
    }
}

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

/// A temporary receiver around the detail artwork; it leaves no player chrome behind.
struct AlbumInsertionOverlay: View {
    let insertion: AlbumInsertion
    let destination: CGRect
    let completion: () -> Void
    @State private var phase = Phase.source

    private enum Phase { case source, lifted, aligned, seated, finished }

    private var artworkFrame: CGRect {
        switch phase {
        case .source: insertion.source
        case .lifted: insertion.source.offsetBy(dx: 0, dy: -10)
        case .aligned: destination.offsetBy(dx: 0, dy: -18)
        case .seated, .finished: destination
        }
    }

    private var tilt: Double {
        switch phase {
        case .lifted: -3
        case .aligned: -1.5
        default: 0
        }
    }

    private var receiverVisible: Bool { phase != .source && phase != .finished }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
                .frame(width: destination.width + 8, height: destination.height + 8)
                .position(x: destination.midX, y: destination.midY)
                .opacity(receiverVisible ? 1 : 0)

            AlbumArtwork(album: insertion.album)
                .frame(width: artworkFrame.width, height: artworkFrame.height)
                .scaleEffect(phase == .lifted ? 1.035 : 1)
                .rotationEffect(.degrees(tilt))
                .position(x: artworkFrame.midX, y: artworkFrame.midY)

            // The cover slips behind this lip as it seats, giving the motion a physical endpoint.
            Capsule()
                .fill(.clear)
                .frame(width: destination.width + 12, height: 14)
                .controlGlass(cornerRadius: 7)
                .overlay {
                    Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
                .position(x: destination.midX, y: destination.maxY - 1)
                .opacity(receiverVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            do {
                withAnimation(.easeOut(duration: 0.12)) { phase = .lifted }
                try await Task.sleep(for: .milliseconds(120))
                withAnimation(.smooth(duration: 0.36)) { phase = .aligned }
                try await Task.sleep(for: .milliseconds(360))
                withAnimation(.spring(duration: 0.22, bounce: 0.08)) { phase = .seated }
                try await Task.sleep(for: .milliseconds(240))
                withAnimation(.easeOut(duration: 0.12)) { phase = .finished }
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                completion()
            } catch {
                // Navigating away removes this overlay and cancels its sequence.
            }
        }
        // A resize or scroll invalidates the captured path; reveal the actual cover immediately.
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
