import SwiftUI

private enum PlayerType {
    static func title(compact: Bool) -> Font { .custom("HelveticaNeue-Medium", size: compact ? 28 : 34) }
    static let artist = Font.custom("HelveticaNeue", size: 14)
    static let edition = Font.custom("HelveticaNeue", size: 12)
    static let track = Font.custom("HelveticaNeue", size: 14)
    static let activeTrack = Font.custom("HelveticaNeue-Medium", size: 14)
    static let number = Font.custom("HelveticaNeue", size: 12)
    static let secondaryNumber = Font.custom("HelveticaNeue", size: 11)
}

struct StageView: View {
    @Bindable var model: AppModel
    let album: Album
    @State private var revealed = false
    @Namespace private var currentRow
    @MotionPreference private var reduceMotion
    private var current: Bool { model.playback?.context?.uri == album.albumID.uri }
    private var moving: Bool { current && model.playback?.isPlaying == true && model.isForeground }
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
        return model.tracks.first { $0.spotifyID == item.id || ($0.trackNumber == item.trackNumber && $0.discNumber == item.discNumber) }?.id
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980 || geometry.size.height < 590
            let artSize = min(380, max(200, geometry.size.height - 245), (geometry.size.width - 116) * 0.49 - 64)
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    GlyphButton(symbol: "arrow.left", label: "返回专辑") { model.selectedAlbum = nil }
                        .accessibilityIdentifier("backToCollection")
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle").font(.system(size: 12))
                        Text(String(model.history.albums[album.id, default: 0])).font(PlayerType.number).contentTransition(.numericText())
                    }.foregroundStyle(Color.quiet)
                        .help("本机收听次数：同一专辑收听累计 30 秒记一次，从使用 Albumer 开始统计")
                        .accessibilityLabel("本机收听 \(model.history.albums[album.id, default: 0]) 次")
                        .accessibilityIdentifier("albumPlayCount")
                    GlyphButton(symbol: model.savedIDs.contains(album.id) ? "checkmark.circle.fill" : "plus.circle", label: model.savedIDs.contains(album.id) ? "移除收藏" : "收藏专辑", active: model.savedIDs.contains(album.id)) {
                        Task { await model.toggleSaved(album) }
                    }.disabled(model.isSaving || !model.checkedSavedIDs.contains(album.id)).accessibilityIdentifier("saveAlbum")
                }.padding(.horizontal, 22)
                HStack(spacing: compact ? 30 : 48) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ZStack {
                            AlbumHalo(model: model, album: album, active: moving)
                                .frame(width: artSize + 86, height: artSize + 86)
                            AlbumArtwork(album: album, radius: 5).frame(width: artSize, height: artSize)
                                .shadow(color: .black.opacity(0.55), radius: 28, y: 16)
                        }.frame(width: artSize + 64, height: artSize + 64)
                        if current {
                            PlaybackProgress(model: model).frame(width: artSize).padding(.top, 7)
                        } else {
                            Capsule().fill(Color.paper.opacity(0.08)).frame(width: artSize, height: 2).padding(.top, 24).padding(.bottom, 14)
                        }
                        HStack(spacing: 32) {
                            GlyphButton(symbol: "backward.end.fill", label: "上一首", size: 36) { Task { await model.perform(.previous) } }
                                .disabled(!current || model.isBusy || model.playback?.allows("skipping_prev") == false)
                            PlayButton(playing: current && model.playback?.isPlaying == true, busy: model.isBusy, size: 54) {
                                Task { await model.play(album) }
                            }.disabled(album.restrictions != nil || (current && model.playback?.allows(model.playback?.isPlaying == true ? "pausing" : "resuming") == false))
                            GlyphButton(symbol: "forward.end.fill", label: "下一首", size: 36) { Task { await model.perform(.next) } }
                                .disabled(!current || model.isBusy || model.playback?.allows("skipping_next") == false)
                        }.padding(.top, 14)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(heading.title).font(PlayerType.title(compact: compact)).tracking(compact ? -0.55 : -0.8)
                            .lineSpacing(3).lineLimit(3).fixedSize(horizontal: false, vertical: true).help(album.name)
                        if let edition = heading.edition {
                            Text(edition).font(PlayerType.edition).tracking(0.2)
                                .foregroundStyle(Color.paper.opacity(0.55)).lineLimit(2).padding(.top, 8)
                        }
                        Text(album.artist).font(PlayerType.artist).tracking(0.1)
                            .foregroundStyle(Color.paper.opacity(0.72)).lineLimit(2).padding(.top, 14)
                        HStack(spacing: 16) {
                            Text(album.year)
                            Rectangle().fill(Color.paper.opacity(0.16)).frame(width: 1, height: 10)
                            HStack(spacing: 6) {
                                Image(systemName: "music.note.list").font(.system(size: 10, weight: .regular)).opacity(0.8)
                                Text(String(album.totalTracks))
                            }.accessibilityElement(children: .ignore).accessibilityLabel("\(album.totalTracks) 首曲目")
                            if !model.tracks.isEmpty {
                                Rectangle().fill(Color.paper.opacity(0.16)).frame(width: 1, height: 10)
                                HStack(spacing: 6) {
                                    Image(systemName: "clock").font(.system(size: 10, weight: .regular)).opacity(0.8)
                                    Text(PlaybackProgress.time(Double(model.tracks.reduce(0) { $0 + $1.durationMS }) / 1000))
                                }
                            }
                        }.font(PlayerType.number).monospacedDigit().tracking(0.15)
                            .foregroundStyle(Color.paper.opacity(0.58)).padding(.top, 18)
                        Rectangle().fill(Color.paper.opacity(0.075)).frame(height: 1).padding(.top, 25).padding(.bottom, 12)
                        trackList
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, compact ? 16 : 38).padding(.bottom, 12)
                        .opacity(revealed ? 1 : 0).offset(x: revealed || reduceMotion ? 0 : 14)
                }.padding(.horizontal, compact ? 32 : 44).padding(.bottom, 12)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): model.lightPosition = UnitPoint(x: 0.3 + point.x / geometry.size.width * 0.4, y: 0.25 + point.y / geometry.size.height * 0.4)
                case .ended: model.lightPosition = .center
                }
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.86)) { revealed = true } }
    }

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.tracks.isEmpty && model.isLoadingTracks {
                        ForEach(0..<7) { index in
                            HStack(spacing: 16) {
                                Capsule().fill(.white.opacity(0.04)).frame(width: 18, height: 5)
                                Capsule().fill(.white.opacity(0.035)).frame(width: CGFloat(110 + (index * 29) % 120), height: 6)
                                Spacer()
                            }.frame(height: 43).padding(.horizontal, 12)
                        }
                    }
                    ForEach(model.tracks) { track in
                        let playing = track.id == currentTrackID
                        HStack(spacing: 15) {
                            ZStack {
                                if playing { PlaybackPulse(active: moving).frame(width: 16, height: 16) }
                                else { Text(String(track.trackNumber)).font(PlayerType.number).monospacedDigit().foregroundStyle(Color.paper.opacity(0.42)) }
                            }.frame(width: 20)
                            Text(track.name).font(playing ? PlayerType.activeTrack : PlayerType.track)
                                .foregroundStyle(playing ? Color.paper : Color.paper.opacity(0.8)).lineLimit(1).help(track.name)
                            Spacer(minLength: 6)
                            if let count = model.history.tracks[track.id], count > 0 {
                                Text(String(count)).font(PlayerType.secondaryNumber).monospacedDigit().foregroundStyle(Color.paper.opacity(0.45))
                                    .help("本机收听 \(count) 次")
                            }
                            Text(PlaybackProgress.time(Double(track.durationMS) / 1000)).font(PlayerType.number).monospacedDigit()
                                .foregroundStyle(Color.paper.opacity(playing ? 0.72 : 0.54)).frame(width: 44, alignment: .trailing)
                        }.padding(.horizontal, 10).frame(height: 42)
                            .background {
                                if playing {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.paper.opacity(0.065))
                                        .matchedGeometryEffect(id: "currentTrack", in: currentRow)
                                }
                            }
                            .id(track.id).accessibilityElement(children: .combine)
                            .accessibilityLabel("\(track.trackNumber). \(track.name)\(playing ? "，正在播放" : "")")
                            .accessibilityIdentifier("track-\(track.id)")
                    }
                    if model.tracksFailed {
                        GlyphButton(symbol: "arrow.clockwise", label: "重试加载曲目") { Task { await model.loadTracks(album) } }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 3)
            }.scrollIndicators(.hidden).accessibilityIdentifier("albumTracks")
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: currentTrackID)
                .onChange(of: currentTrackID) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) } }
                }
        }
    }
}

struct PlayButton: View {
    var playing: Bool
    var busy: Bool
    var size: CGFloat = 38
    var action: () -> Void
    @MotionPreference private var reduceMotion
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.paper)
                if busy { ProgressView().controlSize(.small).tint(Color.room) }
                else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.28, weight: .semibold)).foregroundStyle(Color.room)
                        .offset(x: playing ? 0 : 1)
                        .contentTransition(.symbolEffect(.replace, options: .speed(1.5)))
                }
            }.frame(width: size, height: size)
        }.buttonStyle(.plain).disabled(busy)
            .accessibilityLabel(playing ? "暂停" : "播放")
            .accessibilityIdentifier("playPause")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: playing)
    }
}

struct PlaybackProgress: View {
    @Bindable var model: AppModel
    @State private var scrubbing = false
    @State private var value = 0.0
    var body: some View {
        TimelineView(.periodic(from: .now, by: model.isForeground && model.playback?.isPlaying == true ? 0.25 : 60)) { context in
            let duration = Double(model.playback?.item?.durationMS ?? 1) / 1000
            let position = model.playback?.position(at: context.date) ?? 0
            VStack(spacing: 3) {
                Slider(value: Binding(get: { scrubbing ? value : position }, set: { value = $0 }), in: 0...max(1, duration)) { editing in
                    if editing { value = position }
                    scrubbing = editing
                    if !editing { Task { await model.perform(.seek(Int(value * 1000))) } }
                }
                .controlSize(.mini).tint(Color.paper.opacity(0.65))
                .disabled(model.isBusy || model.playback?.allows("seeking") == false)
                .accessibilityLabel("播放进度").accessibilityIdentifier("playbackProgress")
                HStack {
                    Text(Self.time(scrubbing ? value : position))
                    Spacer()
                    Text(Self.time(duration))
                }.font(PlayerType.secondaryNumber).monospacedDigit().foregroundStyle(Color.paper.opacity(0.54))
            }
        }
    }
    static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct MiniPlayer: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            HStack(spacing: 14) {
                if let album = model.playingAlbum {
                    Button { if album.isAllowed { model.select(album) } } label: {
                        HStack(spacing: 13) {
                            AlbumArtwork(album: album, radius: 4).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.playback?.item?.name ?? album.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(album.artist).font(.system(size: 11)).foregroundStyle(Color.quiet).lineLimit(1)
                            }.frame(maxWidth: 180, alignment: .leading)
                        }
                    }.buttonStyle(.plain).help(album.name).accessibilityLabel("查看正在播放的专辑")
                }
                Spacer(minLength: 6)
                GlyphButton(symbol: "backward.end.fill", label: "上一首", size: 28) { Task { await model.perform(.previous) } }
                    .disabled(model.isBusy || model.playback?.allows("skipping_prev") == false)
                PlayButton(playing: model.playback?.isPlaying == true, busy: model.isBusy) { Task { await model.togglePlayback() } }
                    .disabled(model.playback?.allows(model.playback?.isPlaying == true ? "pausing" : "resuming") == false)
                GlyphButton(symbol: "forward.end.fill", label: "下一首", size: 28) { Task { await model.perform(.next) } }
                    .disabled(model.isBusy || model.playback?.allows("skipping_next") == false)
                PlaybackProgress(model: model).frame(minWidth: 100, idealWidth: 180, maxWidth: 230).padding(.horizontal, 15)
                Spacer(minLength: 0)
                VolumeControl(model: model)
                SpotifyAttribution(album: model.playingAlbum).padding(.leading, 16)
            }.padding(.horizontal, 36).frame(height: 84)
                .background(Color.room.opacity(0.7))
        }
    }
}

struct VolumeControl: View {
    @Bindable var model: AppModel
    @State private var showing = false
    @State private var volume = 50.0
    var body: some View {
        GlyphButton(symbol: "speaker.wave.2", label: "音量", size: 30) {
            volume = Double(model.playback?.device?.volumePercent ?? 50); showing.toggle()
        }
        .disabled(model.playback?.device?.supportsVolume != true)
        .popover(isPresented: $showing) {
            HStack {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(Color.quiet)
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { Task { await model.perform(.volume(Int(volume))) } }
                }.tint(Color.paper).disabled(model.isBusy).accessibilityLabel("音量")
                Text("\(Int(volume))").font(.system(size: 10, design: .monospaced)).frame(width: 25)
            }.padding(20).frame(width: 240).preferredColorScheme(.dark)
        }
    }
}
