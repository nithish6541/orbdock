import AppKit

/// No icon, no menu, no controls. The Dock simply takes on the colors of whatever is playing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = GlowModel()
    private let music = MusicBridge()
    private let backdrop = DockBackdrop()
    private var frameTimer: Timer?
    private var lastFrame = CACurrentMediaTime()
    private var hasArtwork = false
    private var pendingRest: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        if !AXIsProcessTrusted() {
            // Needed only to find where the Dock is drawn.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        backdrop.startTracking()

        music.onChange = { [weak self] state, track in self?.musicChanged(state, track) }
        music.onArtwork = { [weak self] key, image in self?.artworkArrived(key, image) }
        music.start()
    }

    /// Opening the app again while it's running turns it off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        backdrop.fade(in: false, duration: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { NSApp.terminate(nil) }
        return false
    }

    // MARK: - Music → glow

    private func musicChanged(_ state: PlayState, _ track: Track?) {
        model.targetEnergy = state == .playing ? 1 : 0
        pendingRest?.cancel()
        switch state {
        case .stopped:
            // Nothing playing: let the Dock be the Dock again.
            hasArtwork = false
            backdrop.fade(in: false, duration: 2.4)
        case .paused:
            // Settle for a moment, then hand the Dock back.
            let work = DispatchWorkItem { [weak self] in self?.backdrop.fade(in: false, duration: 2.4) }
            pendingRest = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        case .playing:
            if hasArtwork { backdrop.fade(in: true, duration: 1.6) }
        }
        scheduleFrames()
    }

    private func artworkArrived(_ key: String, _ image: NSImage?) {
        guard let track = music.track, track.key == key else { return }
        let swatch = image.flatMap(Swatch.from(artwork:)) ?? .fallback(for: "\(track.album)|\(track.artist)")
        hasArtwork = true
        if backdrop.shown {
            model.fuse(into: swatch)        // melt into the new album
        } else {
            model.set(swatch)               // wake up already wearing it
            render()
            if music.state == .playing {
                backdrop.fade(in: true, duration: 1.6)
            }
        }
        scheduleFrames()
    }

    // MARK: - Frame loop

    private var preferredFPS: Double {
        guard backdrop.shown else { return 0 }
        if model.isTransitioning { return 30 }
        return model.energy > 0.5 ? 24 : 4
    }

    private func scheduleFrames() {
        let fps = preferredFPS
        let interval = fps > 0 ? 1 / fps : 0
        if let t = frameTimer, abs(t.timeInterval - interval) < 0.001 { return }
        frameTimer?.invalidate()
        frameTimer = nil
        guard fps > 0 else { return }
        lastFrame = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.frame() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func frame() {
        let now = CACurrentMediaTime()
        model.step(now - lastFrame)
        lastFrame = now
        render()
        scheduleFrames()
    }

    private func render() {
        guard let size = backdrop.renderSize,
              let image = GlowRenderer.image(width: Int(size.width), height: Int(size.height), model: model) else { return }
        backdrop.setContents(image)
    }
}

// `Orb --render-icon <dir>` writes the icon set used by build.sh.
let args = CommandLine.arguments
if args.count == 3, args[1] == "--render-icon" {
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        renderIcon(to: "\(args[2])/icon_\(name).png", pixels: px)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
