import SwiftUI

@propertyWrapper
struct MotionPreference: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemPreference
    var wrappedValue: Bool { systemPreference || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
}

extension Color {
    static let room = Color(red: 0.055, green: 0.064, blue: 0.063)
    static let paper = Color(red: 0.92, green: 0.91, blue: 0.87)
    static let quiet = Color(red: 0.48, green: 0.51, blue: 0.49)
}

struct RoomBackground: View {
    var accent: Color
    var moving: Bool
    var lightPosition: UnitPoint = .center
    @MotionPreference private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving || reduceMotion)) { timeline in
            let t = moving && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate / 9 : 0
            GeometryReader { proxy in
                ZStack {
                    Color.room
                    MeshGradient(width: 3, height: 3, points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [Float(0.52 + sin(t) * 0.12), Float(0.42 + cos(t * 0.7) * 0.1)], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ], colors: [
                        .room, .room, .room,
                        .room, accent.opacity(0.29), .room,
                        .room, accent.opacity(0.08), .room
                    ], background: .room, smoothsColors: true)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: accent)
                    RadialGradient(colors: [accent.opacity(0.06), .clear], center: reduceMotion ? .center : lightPosition, startRadius: 0, endRadius: 330)
                        .animation(reduceMotion ? nil : .spring(response: 1.1, dampingFraction: 0.9), value: lightPosition)
                    Canvas { context, size in
                        // Stationary fine grain, independent of the animation clock.
                        for i in 0..<900 {
                            let x = Double((i * 7919) % 1009) / 1009 * size.width
                            let y = Double((i * 1543) % 1013) / 1013 * size.height
                            context.fill(Path(CGRect(x: x, y: y, width: 0.7, height: 0.7)), with: .color(.white.opacity(0.035)))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SleeveMark: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08).stroke(Color.paper.opacity(0.3), lineWidth: 1)
                .frame(width: size * 0.62, height: size * 0.79).rotationEffect(.degrees(-12)).offset(x: -size * 0.18)
            RoundedRectangle(cornerRadius: size * 0.08).fill(Color.room)
                .overlay(RoundedRectangle(cornerRadius: size * 0.08).stroke(Color.paper, lineWidth: 1))
                .frame(width: size * 0.68, height: size * 0.84)
            Circle().stroke(Color.paper.opacity(0.8), lineWidth: 1).frame(width: size * 0.37)
            Circle().fill(Color.paper).frame(width: size * 0.06)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct GlyphButton: View {
    let symbol: String
    let label: String
    var active = false
    var size: CGFloat = 36
    var action: () -> Void
    @State private var hovered = false
    @MotionPreference private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.paper : Color.paper.opacity(hovered ? 1 : 0.6))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(active ? 0.10 : hovered ? 0.065 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}

struct AlbumArtwork: View {
    let album: Album
    var radius: CGFloat = 8
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.035))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                SleeveMark(size: 42).opacity(0.25)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .task(id: album.artwork?.absoluteString ?? album.id) { image = nil; image = await ImageStore.shared.image(for: album) }
        .accessibilityHidden(true)
    }
}

struct SpotifyAttribution: View {
    var album: Album?
    var body: some View {
        Button {
            NSWorkspace.shared.open(album?.spotifyURL ?? URL(string: "https://open.spotify.com")!)
        } label: {
            Image("SpotifyLogo").resizable().scaledToFit().frame(width: 78, height: 24)
        }
        .buttonStyle(.plain).opacity(0.65).help("在 Spotify 中打开")
        .accessibilityLabel("在 Spotify 中打开")
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.room : Color.paper)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(prominent ? Color.paper.opacity(configuration.isPressed ? 0.7 : 1) : Color.white.opacity(configuration.isPressed ? 0.1 : 0.055), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.35)
    }
}

