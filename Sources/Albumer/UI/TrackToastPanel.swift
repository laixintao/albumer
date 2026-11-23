import AppKit
import SwiftUI

@MainActor
final class TrackToastPanel {
    static let shared = TrackToastPanel()
    private var panel: ToastWindow?
    private var host: NSHostingView<TrackToastView>?
    private var generation = 0

    func present(_ announcement: TrackAnnouncement) {
        guard let screen = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.screen
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        generation += 1
        let panel = panel ?? makePanel()
        let root = TrackToastView(announcement: announcement)
        if let host { host.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            panel.contentView = host
            self.host = host
        }
        let visible = screen.visibleFrame
        let width = min(380, visible.width - 48)
        panel.setFrame(NSRect(x: visible.maxX - width - 24, y: visible.minY + 24, width: width, height: 108), display: true)
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        generation += 1
        guard let panel, panel.isVisible else { return }
        let generation = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> ToastWindow {
        let panel = ToastWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        self.panel = panel
        return panel
    }
}

private final class ToastWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TrackToastView: View {
    let announcement: TrackAnnouncement
    @State private var loadedArtwork: NSImage?
    @State private var loadedURL: URL?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var artwork: NSImage? {
        guard let url = announcement.artworkURL else { return nil }
        // A new song must never briefly reuse the previous album's cover while its task starts.
        return loadedURL == url ? loadedArtwork : ImageStore.shared.cachedImage(at: url)
    }

    var body: some View {
        ZStack {
            backdrop
                .artworkGlass(cornerRadius: 18)
            // Darken after the glass reflection, so even a white cover stays legible.
            Color.black.opacity(contrast == .increased ? 0.76 : 0.62)
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 5) {
                    Text(announcement.counter)
                        .font(.system(.caption, design: .rounded).weight(.medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.9))
                    Text(announcement.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity).frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
        .padding(10)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(announcement.counter)，\(announcement.name)")
        .task(id: announcement.artworkURL) {
            let url = announcement.artworkURL
            loadedURL = url
            loadedArtwork = url.flatMap { ImageStore.shared.cachedImage(at: $0) }
            guard let url else { return }
            let image = await ImageStore.shared.image(at: url)
            guard !Task.isCancelled else { return }
            loadedArtwork = image
        }
    }

    private var thumbnail: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "opticaldisc").font(.system(size: 26)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.16)
                if !reduceTransparency, let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 14, opaque: true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}
