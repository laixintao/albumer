import SwiftUI

/// A generative listening animation. Connect supplies playback state, not PCM
/// audio, so these curves intentionally make no claim to visualize audio levels.
struct AlbumHalo: View {
    var model: AppModel
    let album: Album
    var active: Bool
    @MotionPreference private var reduceMotion
    @State private var accumulated = 0.0
    @State private var resumedAt = Date.now
    private var animating: Bool { active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
            let t = accumulated + (animating ? timeline.date.timeIntervalSince(resumedAt) : 0)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 5
                let progress = albumProgress(at: timeline.date)
                if active {
                    for light in 0..<3 {
                        let angle = t * 0.13 + Double(light) * .pi * 2 / 3
                        let point = CGPoint(x: center.x + cos(angle) * (radius - 6), y: center.y + sin(angle) * (radius - 6))
                        let glow = Path(ellipseIn: CGRect(x: point.x - 62, y: point.y - 62, width: 124, height: 124))
                        context.fill(glow, with: .radialGradient(Gradient(colors: [model.accent.opacity(0.22), model.accent.opacity(0.04), .clear]), center: point, startRadius: 0, endRadius: 62))
                    }
                }
                for ring in 0..<6 {
                    let r = radius - Double(ring) * 4.5
                    let bounds = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: bounds), with: .color(model.accent.opacity(ring == 0 ? 0.13 : 0.04)), lineWidth: 0.7)
                    var arc = Path()
                    let phase = t * (ring.isMultiple(of: 2) ? 3 : -2) + Double(ring) * 63
                    arc.addArc(center: center, radius: r, startAngle: .degrees(phase), endAngle: .degrees(phase + 42 + Double(ring) * 9), clockwise: false)
                    var glowContext = context
                    glowContext.addFilter(.shadow(color: model.accent.opacity(active ? 0.7 : 0), radius: 6))
                    glowContext.stroke(arc, with: .color(model.accent.opacity(active ? 0.66 - Double(ring) * 0.07 : 0.08)), style: StrokeStyle(lineWidth: ring == 0 ? 1.7 : 0.8, lineCap: .round))
                }
                if progress > 0 {
                    var progressArc = Path()
                    progressArc.addArc(center: center, radius: radius + 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + progress * 360), clockwise: false)
                    context.stroke(progressArc, with: .color(Color.paper.opacity(0.32)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    let angle = (-90 + progress * 360) * .pi / 180
                    let dot = CGPoint(x: center.x + cos(angle) * (radius + 2), y: center.y + sin(angle) * (radius + 2))
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(Color.paper.opacity(0.8)))
                }
                for i in 0..<56 {
                    let angle = Double(i) / 56 * .pi * 2
                    let length = active ? 2 + (sin(t * 0.8 + Double(i) * 0.7) + 1) * 2.5 : 2
                    var tick = Path()
                    tick.move(to: CGPoint(x: center.x + cos(angle) * (radius - 31), y: center.y + sin(angle) * (radius - 31)))
                    tick.addLine(to: CGPoint(x: center.x + cos(angle) * (radius - 31 - length), y: center.y + sin(angle) * (radius - 31 - length)))
                    context.stroke(tick, with: .color(Color.paper.opacity(0.08)), lineWidth: 0.7)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of: animating) { wasActive, isActive in
                if wasActive { accumulated += Date.now.timeIntervalSince(resumedAt) }
                if isActive { resumedAt = .now }
            }
    }
    private func albumProgress(at date: Date) -> Double {
        guard model.playback?.context?.uri == album.albumID.uri, let item = model.playback?.item else { return 0 }
        let duration = model.tracks.reduce(0) { $0 + $1.durationMS }
        guard duration > 0 else { return 0 }
        let before = model.tracks.prefix { track in
            track.spotifyID != item.id && !(track.trackNumber == item.trackNumber && track.discNumber == item.discNumber)
        }.reduce(0) { $0 + $1.durationMS }
        return min(1, max(0, (Double(before) + (model.playback?.position(at: date) ?? 0) * 1000) / Double(duration)))
    }
}

struct PlaybackPulse: View {
    var active: Bool
    @MotionPreference private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !active || reduceMotion)) { timeline in
            let time = active && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                for i in 0..<4 {
                    let height = active ? 4 + (sin(time * 3 + Double(i) * 1.8) + 1) * 5 : 3
                    let rect = CGRect(x: Double(i) * 4, y: (size.height - height) / 2, width: 2, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color.paper.opacity(0.8)))
                }
            }
        }.accessibilityHidden(true)
    }
}
