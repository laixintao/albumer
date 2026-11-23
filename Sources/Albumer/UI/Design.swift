import SwiftUI

@propertyWrapper
struct MotionPreference: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemPreference
    var wrappedValue: Bool { systemPreference || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
}

extension Color {
    static let contentBackground = Color(nsColor: .textBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
}

extension View {
    @ViewBuilder
    func controlGlass(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Clear glass preserves the colors of artwork placed behind the information surface.
    @ViewBuilder
    func artworkGlass(cornerRadius: CGFloat = 6) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func albumButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }
}

struct GlassControls<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { Label(label, systemImage: symbol) }
            .labelStyle(.iconOnly)
            .albumButtonStyle()
            .controlSize(.regular)
            .help(label)
            .accessibilityLabel(label)
    }
}

struct AlbumCollectionButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("专辑收藏", systemImage: "square.stack")
        }
        .labelStyle(.iconOnly)
        .help("专辑收藏")
    }
}

/// Borderless content controls. Toolbar buttons use the system's automatic style.
struct GlyphButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct AlbumArtwork: View {
    let album: Album
    var radius: CGFloat = 6
    @State private var image: NSImage?

    init(album: Album, radius: CGFloat = 6) {
        self.album = album
        self.radius = radius
        _image = State(initialValue: ImageStore.shared.cachedImage(for: album))
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .task(id: album.artwork?.absoluteString ?? album.id) {
            image = ImageStore.shared.cachedImage(for: album)
            let loaded = await ImageStore.shared.image(for: album)
            if !Task.isCancelled { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

struct SpotifyAttribution: View {
    var album: Album?
    var body: some View {
        Button {
            NSWorkspace.shared.open(album?.spotifyURL ?? URL(string: "https://open.spotify.com")!)
        } label: {
            SpotifyWordmark()
        }
        .buttonStyle(.plain)
        .help("在 Spotify 中打开")
        .accessibilityLabel("在 Spotify 中打开")
    }
}

struct SpotifyWordmark: View {
    var width: CGFloat = 78
    var body: some View {
        Image("SpotifyLogo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: width, height: width * 24 / 78)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }
}

