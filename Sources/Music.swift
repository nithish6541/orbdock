import AppKit

/// The music apps Orb listens to.
enum Player: CaseIterable {
    case music, spotify

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    var trackIDKey: String { self == .music ? "PersistentID" : "Track ID" }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var snapshotScript: String {
        let idProperty = self == .music ? "persistent ID" : "id"
        return """
        tell application id "\(bundleID)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (\(idProperty) of t)
        end tell
        """
    }

    var artworkScript: String {
        switch self {
        case .music:
            return """
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
        case .spotify:
            return """
            tell application id "com.spotify.client" to return artwork url of current track
            """
        }
    }
}

struct Track: Equatable {
    var player: Player
    var key: String
    var title: String
    var artist: String
    var album: String
}

enum PlayState { case playing, paused, stopped }

/// Listens to Apple Music and Spotify. State changes arrive via each app's distributed notification (free, instant);
/// AppleScript is only used for artwork and the initial snapshot. When both report, the one playing most recently wins.
final class MusicBridge {
    var onChange: ((PlayState, Track?) -> Void)?
    var onArtwork: ((String, NSImage?) -> Void)?

    private(set) var state: PlayState = .stopped
    private(set) var track: Track?

    private var reports: [Player: (state: PlayState, track: Track?)] = [:]
    private var active: Player?

    /// AppleScript runs on one private serial queue so it never stalls animation.
    private let queue = DispatchQueue(label: "orb.music", qos: .userInitiated)
    private var pendingStops: [Player: DispatchWorkItem] = [:]

    func start() {
        for player in Player.allCases {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(playerInfo(_:)), name: .init(player.notification), object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refresh()
    }

    /// Reads the current state directly. Never launches a player.
    func refresh() {
        for player in Player.allCases {
            guard player.isRunning else { report(player, .stopped, nil); continue }
            queue.async { [weak self] in
                guard let out = Self.run(player.snapshotScript)?.stringValue else { return }
                let parts = out.components(separatedBy: "\n")
                DispatchQueue.main.async {
                    guard parts.count >= 5 else { self?.report(player, .stopped, nil); return }
                    let state: PlayState = parts[0] == "playing" ? .playing : .paused
                    self?.report(player, state, Track(player: player, key: parts[4], title: parts[1], artist: parts[2], album: parts[3]))
                }
            }
        }
    }

    // MARK: - Events

    @objc private func playerInfo(_ note: Notification) {
        guard let player = Player.allCases.first(where: { $0.notification == note.name.rawValue }) else { return }
        let info = note.userInfo ?? [:]
        let stateString = info["Player State"] as? String ?? "Stopped"
        let state: PlayState = stateString == "Playing" ? .playing : stateString == "Paused" ? .paused : .stopped

        // Music reports a momentary "Stopped" between every two songs. Only believe it if nothing follows,
        // otherwise a song change would look like the music ending and starting again.
        pendingStops[player]?.cancel()
        guard state != .stopped else {
            let work = DispatchWorkItem { [weak self] in self?.report(player, .stopped, nil) }
            pendingStops[player] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            return
        }

        let previous = reports[player]?.track
        let title = info["Name"] as? String ?? previous?.title ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let key = (info[player.trackIDKey]).map { "\($0)" } ?? "\(title)|\(artist)|\(album)"
        report(player, state, Track(player: player, key: key, title: title, artist: artist, album: album))
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let player = Player.allCases.first(where: { $0.bundleID == app?.bundleIdentifier }) else { return }
        pendingStops[player]?.cancel()
        report(player, .stopped, nil)
    }

    /// Records what one player says, then shows whichever player should own the Dock.
    private func report(_ player: Player, _ newState: PlayState, _ newTrack: Track?) {
        reports[player] = (newState, newTrack)
        if newState == .playing {
            active = player
        } else if active == nil || active == player,
                  let other = Player.allCases.first(where: { $0 != player && reports[$0]?.state == .playing }) {
            active = other
        } else if active == nil {
            active = player
        }
        let current = active.flatMap { reports[$0] } ?? (.stopped, nil)
        apply(current.state, current.track)
    }

    private func apply(_ newState: PlayState, _ newTrack: Track?) {
        let trackChanged = newTrack?.key != track?.key
        guard newState != state || newTrack != track else { return }
        state = newState
        track = newTrack
        onChange?(newState, newTrack)
        if trackChanged, let t = newTrack { fetchArtwork(for: t) }
    }

    // MARK: - Artwork

    private func fetchArtwork(for track: Track) {
        let key = track.key
        queue.async { [weak self] in
            let result = Self.run(track.player.artworkScript)
            let deliver: (NSImage?) -> Void = { image in
                DispatchQueue.main.async {
                    guard let self, let track = self.track, track.key == key else { return }
                    if let image {
                        self.onArtwork?(key, image)
                    } else {
                        // Streamed tracks may expose no artwork to scripts; ask Apple's catalog instead.
                        self.lookUpArtwork(for: track) { [weak self] found in
                            guard let self, self.track?.key == key else { return }
                            self.onArtwork?(key, found)
                        }
                    }
                }
            }
            switch track.player {
            case .music:
                deliver(result.flatMap { NSImage(data: $0.data) })
            case .spotify:
                // Spotify hands out a URL to the cover rather than the image itself.
                guard let url = result?.stringValue.flatMap(URL.init(string:)) else { deliver(nil); return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    deliver(data.flatMap(NSImage.init(data:)))
                }.resume()
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
