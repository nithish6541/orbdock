import AppKit

struct Track: Equatable {
    var key: String
    var title: String
    var artist: String
    var album: String
}

enum PlayState { case playing, paused, stopped }

/// Listens to Apple Music. State changes arrive via Music's distributed notification (free, instant);
/// AppleScript is only used for artwork and the initial snapshot.
final class MusicBridge {
    static let bundleID = "com.apple.Music"

    var onChange: ((PlayState, Track?) -> Void)?
    var onArtwork: ((String, NSImage?) -> Void)?

    private(set) var state: PlayState = .stopped
    private(set) var track: Track?

    /// AppleScript runs on one private serial queue so it never stalls animation.
    private let queue = DispatchQueue(label: "orb.music", qos: .userInitiated)
    private var pendingStop: DispatchWorkItem?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfo(_:)), name: .init("com.apple.Music.playerInfo"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refresh()
    }

    /// Reads the current state directly. Never launches Music.
    func refresh() {
        guard isRunning else { apply(.stopped, nil); return }
        queue.async { [weak self] in
            let script = """
            tell application id "com.apple.Music"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (persistent ID of t)
            end tell
            """
            guard let out = Self.run(script)?.stringValue else { return }
            let parts = out.components(separatedBy: "\n")
            DispatchQueue.main.async {
                guard parts.count >= 5 else { self?.apply(.stopped, nil); return }
                let state: PlayState = parts[0] == "playing" ? .playing : .paused
                self?.apply(state, Track(key: parts[4], title: parts[1], artist: parts[2], album: parts[3]))
            }
        }
    }

    // MARK: - Events

    @objc private func playerInfo(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let stateString = info["Player State"] as? String ?? "Stopped"
        let state: PlayState = stateString == "Playing" ? .playing : stateString == "Paused" ? .paused : .stopped

        // Music reports a momentary "Stopped" between every two songs. Only believe it if nothing follows,
        // otherwise a song change would look like the music ending and starting again.
        pendingStop?.cancel()
        guard state != .stopped else {
            let work = DispatchWorkItem { [weak self] in self?.apply(.stopped, nil) }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }

        let title = info["Name"] as? String ?? track?.title ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let key = (info["PersistentID"]).map { "\($0)" } ?? "\(title)|\(artist)|\(album)"
        apply(state, Track(key: key, title: title, artist: artist, album: album))
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.bundleID { pendingStop?.cancel(); apply(.stopped, nil) }
    }

    private func apply(_ newState: PlayState, _ newTrack: Track?) {
        let trackChanged = newTrack?.key != track?.key
        guard newState != state || newTrack != track else { return }
        state = newState
        track = newTrack
        onChange?(newState, newTrack)
        if trackChanged, let t = newTrack { fetchArtwork(for: t.key) }
    }

    // MARK: - Artwork

    private func fetchArtwork(for key: String) {
        queue.async { [weak self] in
            let script = """
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    try
                        return data of artwork 1 of current track
                    end try
                end try
            end tell
            """
            let image = Self.run(script).flatMap { NSImage(data: $0.data) }
            DispatchQueue.main.async {
                guard let self, let track = self.track, track.key == key else { return }
                if let image {
                    self.onArtwork?(key, image)
                } else {
                    // Streamed Apple Music tracks expose no artwork to scripts; ask Apple's catalog instead.
                    self.lookUpArtwork(for: track) { [weak self] found in
                        guard let self, self.track?.key == key else { return }
                        self.onArtwork?(key, found)
                    }
                }
            }
        }
    }

    private var catalogCache: [String: NSImage] = [:]

    /// Finds the official cover through the public iTunes Search API, matching title, artist and album.
    private func lookUpArtwork(for track: Track, completion: @escaping (NSImage?) -> Void) {
        let albumKey = "\(track.artist)|\(track.album)"
        if let cached = catalogCache[albumKey] { completion(cached); return }

        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [
            .init(name: "media", value: "music"), .init(name: "entity", value: "song"), .init(name: "limit", value: "10"),
            .init(name: "term", value: "\(track.title) \(track.artist) \(track.album)"),
        ]
        URLSession.shared.dataTask(with: query.url!) { [weak self] data, _, _ in
            let results = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["results"] as? [[String: Any]] ?? []
            func matches(_ r: [String: Any], _ field: String, _ value: String) -> Bool {
                (r[field] as? String)?.caseInsensitiveCompare(value) == .orderedSame
            }
            // Prefer the exact album, then the right artist, then whatever came first.
            let best = results.first { matches($0, "collectionName", track.album) && matches($0, "artistName", track.artist) }
                ?? results.first { matches($0, "collectionName", track.album) }
                ?? results.first { matches($0, "artistName", track.artist) }
                ?? results.first
            guard let small = best?["artworkUrl100"] as? String,
                  let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    if let image { self?.catalogCache[albumKey] = image }
                    completion(image)
                }
            }.resume()
        }.resume()
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
