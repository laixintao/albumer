import SwiftUI

struct StageView: View {
    @Bindable var model: AppModel
    let album: Album
    var inserting = false
    var artworkFrameChanged: (CGRect) -> Void = { _ in }
    @MotionPreference private var reduceMotion

    private var current: Bool {
        model.playingAlbumID == album.albumID
    }
    private var heading: (title: String, edition: String?) {
        let name = album.name
        guard name.hasSuffix(")"), let suffix = name.range(of: " (", options: .backwards) else { return (name, nil) }
        let edition = String(name[suffix.upperBound...].dropLast())
        let qualifiers = ["edition", "deluxe", "remaster", "anniversary", "expanded", "version", "stereo", "mono", "mix"]
        guard qualifiers.contains(where: { edition.localizedCaseInsensitiveContains($0) }) else { return (name, nil) }
        return (String(name[..<suffix.lowerBound]), edition)
    }
    private var currentTrackID: String? {
        guard current, let item = model.playback?.item else { return nil }
        return model.tracks.first {
            ($0.spotifyID != nil && $0.spotifyID == item.id) || ($0.trackNumber == item.trackNumber && $0.discNumber == item.discNumber)
        }?.id
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                albumDetails
                    .frame(width: min(320, max(264, geometry.size.width * 0.28)))
                Divider()
                VStack(spacing: 0) {
                    PlaybackDevicesView(model: model)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
                    trackHeader
                    Divider().padding(.horizontal, 20)
                    trackList
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var albumDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AlbumArtwork(album: album)
                    .opacity(inserting ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AlbumInsertion.coordinateSpace)) } action: {
                        artworkFrameChanged($0)
                    }
                    .anchorPreference(key: AlbumArtworkDestinationKey.self, value: .bounds) {
                        AlbumArtworkDestination(albumID: album.id, bounds: $0)
                    }
                AlbumPlaybackControls(model: model, album: album)
                if current, let track = model.playback?.item {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            PlaybackIndicator(playing: model.playback?.isPlaying == true)
                            Text(track.name).font(.callout).lineLimit(2).help(track.name)
                        }
                        PlaybackProgress(model: model)
                    }
                    .accessibilityIdentifier("albumPlaybackInfo")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading.title).font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let edition = heading.edition {
                        Text(edition).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(album.artists.enumerated()), id: \.offset) { _, artist in
                        ArtistLink(model: model, artist: artist)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    AlbumDetailLabel(symbol: "calendar", text: album.releaseYear.map(String.init) ?? "年份未知", label: "发行年份")
                    AlbumDetailLabel(symbol: "music.note.list", text: "\(album.totalTracks) 首", label: "曲目数量")
                    if !model.tracks.isEmpty {
                        AlbumDetailLabel(
                            symbol: "clock",
                            text: PlaybackProgress.time(Double(model.tracks.reduce(0) { $0 + $1.durationMS }) / 1000),
                            label: "总时长"
                        )
                    }
                    AlbumDetailLabel(symbol: "play.circle", text: "\(model.history.albums[album.id, default: 0]) 次", label: "本机收听")
                        .help("本机收听次数：同一专辑收听累计 30 秒记一次，从使用 Albumer 开始统计")
                        .accessibilityIdentifier("albumPlayCount")
                }
                .accessibilityIdentifier("albumMetadata")
                SavedAlbumButton(model: model, album: album)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("albumDetails")
    }

    private var trackHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 24)
            Text("曲目").frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "clock").frame(width: 44, alignment: .trailing)
                .accessibilityLabel("时长")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 30).frame(height: 34)
        .accessibilityAddTraits(.isHeader)
    }

    private var trackList: some View {
        let discs = AlbumDisc.group(model.tracks)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(discs) { disc in
                        Section {
                            ForEach(Array(disc.tracks.enumerated()), id: \.element.id) { index, track in
                                trackRow(track, index: index, multipleDiscs: discs.count > 1)
                            }
                        } header: {
                            if discs.count > 1 {
                                discHeader(disc, first: disc.id == discs.first?.id)
                            }
                        }
                    }
                    if model.tracksFailed {
                        Button("重试加载曲目", systemImage: "arrow.clockwise") { Task { await model.loadTracks(album) } }
                            .padding(20)
                    } else if model.isLoadingTracks && model.tracks.isEmpty {
                        ProgressView().controlSize(.small).padding(32)
                    } else if model.tracks.isEmpty {
                        Text("暂无曲目").foregroundStyle(.secondary).padding(32)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 6)
            }
            .accessibilityIdentifier("albumTracks")
            .onChange(of: currentTrackID) { _, id in
                if let id {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func discHeader(_ disc: AlbumDisc, first: Bool) -> some View {
        HStack(spacing: 12) {
            Label("唱片 \(disc.number)", systemImage: "opticaldisc")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Label("\(disc.tracks.count) 首", systemImage: "music.note.list")
                .font(.caption).foregroundStyle(.secondary)
            Label(PlaybackProgress.time(Double(disc.durationMS) / 1000), systemImage: "clock")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .padding(.top, first ? 0 : 12)
        .background(Color.contentBackground)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("disc-\(disc.number)")
    }

    private func trackRow(_ track: AlbumTrack, index: Int, multipleDiscs: Bool) -> some View {
        let playing = track.id == currentTrackID
        let count = model.history.tracks[track.id, default: 0]
        return HStack(spacing: 12) {
            Group {
                if playing {
                    PlaybackIndicator(playing: model.playback?.isPlaying == true)
                } else {
                    Text(String(track.trackNumber)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }.frame(width: 24)
            Text(track.name).font(.body.weight(playing ? .medium : .regular))
                .lineLimit(1).help(track.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > 0 {
                Text(String(count)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("本机收听 \(count) 次")
            }
            Text(PlaybackProgress.time(Double(track.durationMS) / 1000))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 4).fill(
                playing ? Color.accentColor.opacity(0.12) :
                    Color(nsColor: NSColor.alternatingContentBackgroundColors[index % 2])
            )
        }
        .id(track.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(multipleDiscs ? "唱片 \(track.discNumber)，" : "")\(track.trackNumber). \(track.name)\(playing ? (model.playback?.isPlaying == true ? "，正在播放" : "，已暂停") : "")，\(PlaybackProgress.time(Double(track.durationMS) / 1000))，本机收听 \(count) 次")
        .accessibilityIdentifier("track-\(track.id)")
    }
}

struct SavedAlbumButton: View {
    @Bindable var model: AppModel
    let album: Album
    private var saved: Bool { model.savedIDs.contains(album.id) }
    private var pending: Bool { model.savingAlbumID == album.id || model.checkingSavedIDs.contains(album.id) }
    private var needsCheck: Bool { !model.checkedSavedIDs.contains(album.id) }
    private var title: String {
        if model.savingAlbumID == album.id { return "正在保存…" }
        if model.checkingSavedIDs.contains(album.id) { return "正在同步…" }
        if needsCheck { return "重试读取收藏状态" }
        return saved ? "已收藏" : "收藏专辑"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    if needsCheck { await model.checkSaved(album) }
                    else { await model.toggleSaved(album) }
                }
            } label: {
                HStack(spacing: 7) {
                    if pending { ProgressView().controlSize(.small) }
                    else { Image(systemName: needsCheck ? "arrow.clockwise" : (saved ? "checkmark" : "plus")) }
                    Text(title)
                }
            }
            .albumButtonStyle()
            .controlSize(.regular)
            .help(needsCheck ? "重新读取收藏状态" : (saved ? "移除收藏" : "收藏专辑"))
            .accessibilityLabel(pending ? title : (needsCheck ? title : (saved ? "移除收藏" : "收藏专辑")))
            .disabled(model.isSaving || pending)
            .accessibilityIdentifier("saveAlbum")
            if let error = model.saveErrors[album.id] {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saveAlbumError")
            }
        }
    }
}

struct PlayButton: View {
    var playing: Bool
    var busy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill")
                }
            }.frame(minWidth: 52, minHeight: 22)
        }
        .albumButtonStyle(prominent: true)
        .controlSize(.regular)
        .disabled(busy)
        .help(playing ? "暂停" : "播放整张专辑")
        .accessibilityLabel(playing ? "暂停" : "播放")
        .accessibilityIdentifier("playPause")
    }
}

struct PlaybackProgress: View {
    @Bindable var model: AppModel
    @State private var scrubbing = false
    @State private var value = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.isForeground && model.playback?.isPlaying == true ? 0.25 : 60)) { context in
            let duration = Double(model.playback?.item?.durationMS ?? 0) / 1000
            let position = model.playback?.position(at: context.date) ?? 0
            HStack(spacing: 8) {
                Text(Self.time(scrubbing ? value : position)).frame(width: 36, alignment: .trailing)
                Slider(value: Binding(
                    get: { min(max(0, scrubbing ? value : position), max(1, duration)) },
                    set: { value = $0 }
                ), in: 0...max(1, duration)) { editing in
                    if editing { value = position }
                    scrubbing = editing
                    if !editing && model.hasPlayback {
                        Task { await model.perform(.seek(Int(value * 1000))) }
                    }
                }
                .controlSize(.small)
                .disabled(!model.hasPlayback || model.isBusy || model.playback?.allows("seeking") == false)
                .accessibilityLabel("播放进度")
                .accessibilityIdentifier("playbackProgress")
                Text(duration > 0 ? Self.time(duration) : "–:––").frame(width: 36, alignment: .leading)
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .onChange(of: model.playback?.item?.id) { _, _ in scrubbing = false }
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct AlbumPlaybackControls: View {
    @Bindable var model: AppModel
    let album: Album
    private var current: Bool { model.playback?.context?.uri == album.albumID.uri }
    private var playing: Bool { current && model.playback?.isPlaying == true }
    private var playbackUnavailable: Bool {
        !album.isAllowed || album.restrictions != nil ||
            (current && model.playback?.allows(playing ? "pausing" : "resuming") == false)
    }

    var body: some View {
        GlassControls {
            HStack(spacing: 8) {
                PlayButton(playing: playing, busy: model.isBusy) { Task { await model.play(album) } }
                    .disabled(playbackUnavailable)
                Spacer(minLength: 0)
                GlassIconButton(symbol: "backward.end.fill", label: "上一首") { Task { await model.perform(.previous) } }
                    .disabled(!current || model.isBusy || model.playback?.allows("skipping_prev") == false)
                GlassIconButton(symbol: "forward.end.fill", label: "下一首") { Task { await model.perform(.next) } }
                    .disabled(!current || model.isBusy || model.playback?.allows("skipping_next") == false)
                VolumeControl(model: model)
                    .disabled(!current)
            }
        }
        .accessibilityIdentifier("albumPlaybackControls")
    }
}

struct ArtistPortrait: View {
    let model: AppModel
    let artist: Artist
    var size: CGFloat = 32
    var loadEnabled = true
    @State private var image: NSImage?
    @State private var loadedArtist: Artist?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: size * 0.75, weight: .regular)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: loadEnabled ? artist : nil) {
            guard loadEnabled, loadedArtist != artist || image == nil else { return }
            image = nil
            guard let url = await model.artistPortrait(for: artist), !Task.isCancelled else { return }
            let loaded = await ImageStore.shared.image(at: url)
            if !Task.isCancelled { image = loaded; loadedArtist = artist }
        }
    }
}

private struct AlbumDetailLabel: View {
    let symbol: String
    let text: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(text).monospacedDigit()
        }
        .font(.callout).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)：\(text)")
        .help("\(label)：\(text)")
    }
}

struct VolumeControl: View {
    @Bindable var model: AppModel
    @State private var showing = false
    @State private var volume = 50.0

    var body: some View {
        GlassIconButton(symbol: "speaker.wave.2", label: "音量") {
            volume = Double(model.playback?.device?.volumePercent ?? 50)
            showing.toggle()
        }
        .disabled(model.playback?.device?.supportsVolume != true)
        .popover(isPresented: $showing) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { Task { await model.perform(.volume(Int(volume))) } }
                }.disabled(model.isBusy).accessibilityLabel("音量")
                Text("\(Int(volume))").font(.caption).monospacedDigit().frame(width: 26)
            }.padding(20).frame(width: 240)
        }
    }
}
