import SwiftUI

struct ArtistLink: View {
    let model: AppModel
    let artist: Artist
    var portrait = true
    @State private var hovered = false

    var body: some View {
        Button { model.openArtist(artist) } label: {
            HStack(spacing: 10) {
                if portrait { ArtistPortrait(model: model, artist: artist) }
                Text(artist.name).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(hovered ? Color.accentColor : Color.primary)
                if artist.id != nil {
                    Image(systemName: "chevron.right").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(artist.id?.isEmpty != false)
        .onHover { hovered = $0 }
        .help("查看 \(artist.name) 的专辑")
        .accessibilityIdentifier("artist-\(artist.id ?? artist.name)")
    }
}

struct ArtistView: View {
    let model: AppModel
    let catalog: ArtistCatalog
    let selectAlbum: (Album, CGRect) -> Void
    @State private var position = ScrollPosition(y: 0)
    @State private var scrolling = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                ArtistPortrait(model: model, artist: catalog.artist, size: 80)
                VStack(alignment: .leading, spacing: 8) {
                    Text(catalog.artist.name).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                    Label("\(catalog.albums.count) 张专辑", systemImage: "square.stack")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                PlaybackDevicesView(model: model)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    albumSection(saved: true)
                    albumSection(saved: false)
                    if let error = catalog.error {
                        VStack(spacing: 10) {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                            Button("重试加载", systemImage: "arrow.clockwise") {
                                Task { await model.loadArtistCatalog(catalog) }
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    } else if catalog.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                if position.isPositionedByUser, model.selectedArtist === catalog {
                    catalog.scrollOffset = max(0, offset)
                }
            }
            .task { position.scrollTo(y: catalog.scrollOffset) }
        }
        .task { await model.loadArtistCatalog(catalog) }
        .accessibilityIdentifier("artistPage")
    }

    private func albumSection(saved: Bool) -> some View {
        let albums = catalog.albums(saved: saved)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(saved ? "已收藏" : "未收藏", systemImage: saved ? "checkmark.circle" : "square.stack")
                    .font(.headline)
                Text("\(albums.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }.accessibilityAddTraits(.isHeader)
            if albums.isEmpty {
                Text(catalog.error != nil ? "专辑尚未加载" : (catalog.nextOffset != nil ? "正在加载专辑…" : (saved ? "还没有收藏这位艺人的专辑" : "没有未收藏的专辑")))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 184), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                    ForEach(albums) { album in
                        AlbumCard(model: model, album: album, current: model.playingAlbumID == album.albumID,
                                  playing: model.playback?.isPlaying == true,
                                  hoverEnabled: !scrolling && model.isForeground && !model.showSettings,
                                  action: { source in selectAlbum(album, source) })
                    }
                }
            }
        }
        .accessibilityIdentifier(saved ? "artistSavedAlbums" : "artistUnsavedAlbums")
    }
}
