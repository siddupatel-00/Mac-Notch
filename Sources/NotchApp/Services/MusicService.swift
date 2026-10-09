import Foundation
import AVFoundation
import AppKit
import Combine

/// Repeat cycle: off → all → one → off
enum RepeatMode: String {
    case off, all, one
    func next() -> RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// One AVPlayer for everything the notch plays (local files + open streams).
/// Spotify / Apple Music / YT Music apps are *controlled* via AppleScript / URL —
/// we don't re-stream their DRM catalogues, we remote them.
final class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published var isPlaying = false
    @Published var title = "Nothing playing"
    @Published var subtitle = "Pick a source below"
    @Published var source = "Local"
    @Published var volume: Float = UserDefaults.standard.object(forKey: "musicVolume") as? Float ?? 0.8 {
        didSet {
            let v = min(1, max(0, volume))
            if v != volume { volume = v; return }
            UserDefaults.standard.set(v, forKey: "musicVolume")
            player?.volume = v
            YTWebPlayer.shared.setWebVolume(v)
        }
    }

    /// Currently playing stream id (YouTube navigation).
    var currentAudioId: String?
    /// True when the user asked the site to play (strip/media keys/next).
    /// The watchdog auto-resumes only in this state — a deliberate user pause
    /// is never overridden.
    var expectingWebPlay = false

    private var player: AVPlayer?
    private var localTracks: [URL] = []
    private var localIndex = 0
    private let queue = DispatchQueue(label: "notch.music", qos: .userInitiated)
    @Published var durations: [String: Double] = [:]
    // Timeline state for the seek bar
    @Published var position: Double = 0
    @Published var trackLength: Double = 0
    private var timeObserver: Any?
    private var endObserver: Any?
    private var stallTicks = 0
    private var lastPos: Double = -1
    private var playToken = 0
    private var preloadedNext = false
    // Repeat + shuffle (persisted)
    @Published var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "off") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    @Published var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffleOn") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffleOn") }
    }

    var localURLs: [URL] { localTracks }

    init() {
        if let arr = UserDefaults.standard.array(forKey: "localMusic") as? [String] {
            localTracks = arr.compactMap { URL(string: $0) }
        }
        refreshDurations()
        // End-of-track → repeat/shuffle/off behavior.
        // NOTE: the token MUST be retained or the observation silently dies.
        endObserver = NotificationCenter.default.addObserver(forName: Notification.Name("AVPlayerItemDidPlayToEndNotification"), object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let ended = note.object as? AVPlayerItem,
                  ended == self.player?.currentItem else { return }
            self.trackEnded()
        }
    }

    /// Track lengths for the compact list (cached, background-loaded)
    func refreshDurations() {
        let urls = localTracks
        Task {
            for u in urls {
                let k = u.absoluteString
                if await MainActor.run(body: { self.durations[k] != nil }) { continue }
                let asset = AVURLAsset(url: u)
                guard let d = try? await asset.load(.duration), d.isValid else { continue }
                let secs = CMTimeGetSeconds(d)
                guard secs.isFinite, secs > 0 else { continue }
                await MainActor.run { self.durations[k] = secs }
            }
        }
    }

    func durationText(_ url: URL) -> String? {
        guard let s = durations[url.absoluteString], s.isFinite, s > 0 else { return nil }
        return "\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))"
    }

    // MARK: Local files
    func pickLocalFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        guard p.runModal() == .OK else { return }
        localTracks += p.urls
        UserDefaults.standard.set(localTracks.map(\.absoluteString), forKey: "localMusic")
        refreshDurations()
    }

    func playLocal(at i: Int) {
        guard localTracks.indices.contains(i) else { return }
        localIndex = i
        play(url: localTracks[i], title: localTracks[i].lastPathComponent, sub: "Local file", source: "Local", localURL: localTracks[i])
    }

    var localNames: [String] { localTracks.map(\.lastPathComponent) }

    // MARK: Generic play (local files + open streams). Sole audio source: stops everything else.
    func play(url: URL, title: String, sub: String, source: String, localURL: URL? = nil, audioId: String? = nil) {
        stopAppPlayback()
        silenceExternalApps()
        YTWebPlayer.shared.pauseWeb()
        let item = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer()
            timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 2), queue: .main) { [weak self] t in
                guard let self else { return }
                let pos = t.seconds.isFinite ? t.seconds : 0
                self.position = pos
                RemoteCommands.refresh()
                // Gapless: in repeat-all, resolve the deterministic next track while
                // this one finishes (~15s head start), so it starts instantly.
                // Repeat-one replays from cache; shuffle is random (on-demand).
                if self.isPlaying, !self.preloadedNext, self.repeatMode == .all,
                   self.trackLength > 0, pos > 5, self.trackLength - pos < 15 {
                    self.preloadedNext = true
                    self.preloadNext()
                }
                // Truth from motion, not from rate: a stalled stream keeps rate==1
                // forever, so watch whether time actually advances.
                guard self.isPlaying else { self.stallTicks = 0; return }
                if self.player?.currentItem?.status == .failed {
                    self.stallTicks = 0
                    self.isPlaying = false
                    return
                }
                if self.trackLength > 0, pos >= self.trackLength - 0.25 {
                    self.stallTicks = 0
                    self.trackEnded()
                    return
                }
                if pos != self.lastPos {
                    self.lastPos = pos
                    self.stallTicks = 0
                    return
                }
                self.stallTicks += 1
                // Startup grace (pos ~0): allow 10s of buffering; after that, or
                // mid-song, a frozen clock means no audio. Near the end it means over.
                let limit = pos > 5 ? 6 : 20
                guard self.stallTicks >= limit else { return }
                self.stallTicks = 0
                if self.trackLength > 0, self.trackLength - pos < 5 {
                    self.trackEnded()
                } else if pos > 5 {
                    self.isPlaying = false
                }
            }
        }
        player?.replaceCurrentItem(with: item)
        player?.volume = volume
        // Start fast instead of pre-buffering: streams begin in ~1s on decent nets.
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.play()
        position = 0
        lastPos = -1
        stallTicks = 0
        preloadedNext = false
        playToken += 1
        let gen = playToken
        if let known = durations[url.absoluteString] {
            trackLength = known
        } else {
            trackLength = 0
            Task {
                if let d = try? await item.asset.load(.duration), d.isValid {
                    let s = CMTimeGetSeconds(d)
                    if s.isFinite, s > 0 {
                        await MainActor.run {
                            // A previous song's slow load must not overwrite this one.
                            if self.playToken == gen { self.trackLength = s }
                        }
                    }
                }
            }
        }
        PlayHistoryStore.shared.record(title: title, source: source, localURL: localURL, audioId: audioId)
        DispatchQueue.main.async {
            self.isPlaying = true
            self.title = title
            self.subtitle = sub
            self.source = source
            RemoteCommands.refresh()
        }
    }

    func toggle() {
        switch source {
        case "Spotify", "Apple":
            let app = source == "Apple" ? "Music" : "Spotify"
            let willPlay = !isPlaying
            control(app: app, action: "toggle")
            // control() async-pauses AVPlayer and clears isPlaying; re-assert
            // the flipped remote state after it so the strip stays truthful.
            DispatchQueue.main.async {
                self.isPlaying = willPlay
                RemoteCommands.refresh()
            }
            return
        case "YouTube Web":
            YTWebPlayer.shared.toggleWeb()
            // Optimistic flip; the 2s poll corrects it from the page truth.
            // Intent follows what the user SAW: pause icon -> pause, play icon -> play.
            expectingWebPlay = !isPlaying
            isPlaying.toggle()
            RemoteCommands.refresh()
            return
        default:
            break
        }
        if isPlaying { player?.pause(); isPlaying = false }
        else {
            if player?.currentItem != nil { player?.play(); isPlaying = true }
            else if !localTracks.isEmpty { playLocal(at: localIndex) }
        }
        RemoteCommands.refresh()
    }

    /// Media-key surface (F7–F9 / headphones / Touch Bar).
    var hasPlayable: Bool { player?.currentItem != nil || !localTracks.isEmpty || ((source == "Spotify" || source == "Apple") && title != "Nothing playing") || source == "YouTube Web" }
    func resume() {
        if source == "YouTube Web" { expectingWebPlay = true; YTWebPlayer.shared.playWeb(); return }
        if player?.currentItem != nil { player?.play(); isPlaying = true }
        else if !localTracks.isEmpty { playLocal(at: localIndex) }
        RemoteCommands.refresh()
    }
    func pause() {
        if source == "YouTube Web" { YTWebPlayer.shared.pauseWeb() }
        else { player?.pause() }
        expectingWebPlay = false
        isPlaying = false
        RemoteCommands.refresh()
    }
    func next() { nextTrack(); RemoteCommands.refresh() }
    func previous() { prevTrack(); RemoteCommands.refresh() }

    func stopAppPlayback() {
        player?.pause()
        expectingWebPlay = false
        DispatchQueue.main.async { self.isPlaying = false }
    }

    // MARK: Spotify + Apple Music remote (AppleScript, no keys)
    /// Bundle-ID presence checks — pure NSWorkspace, never AppleScript (no launch/dialog side effects).
    private func bundleID(for app: String) -> String? {
        switch app {
        case "Spotify": return "com.spotify.client"
        case "Music": return "com.apple.Music"
        default: return nil
        }
    }

    func isAppInstalled(_ app: String) -> Bool {
        guard let bid = bundleID(for: app) else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
    }

    func isAppRunning(_ app: String) -> Bool {
        guard let bid = bundleID(for: app) else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bid }
    }

    /// Pause the desktop apps so the notch is never layered over them.
    func silenceExternalApps() {
        queue.async {
            for app in ["Spotify", "Music"] {
                guard self.isAppRunning(app) else { continue }
                let script = "if application \"\(app)\" is running then\ntell application \"\(app)\" to pause\nend if"
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
            }
        }
    }

    func control(app: String, action: String, completion: ((String) -> Void)? = nil) {
        guard isAppInstalled(app) else {
            if action == "state", let c = completion {
                DispatchQueue.main.async { c("") }
            }
            return
        }
        if !isAppRunning(app), action != "toggle" {
            if action == "state", let c = completion {
                DispatchQueue.main.async { c("closed") }
            }
            return
        }
        // External app takes over: stop the notch player first — one source at a time.
        if action == "toggle" || action == "next" || action == "prev" {
            YTWebPlayer.shared.pauseWeb()
            expectingWebPlay = false
            DispatchQueue.main.async {
                self.player?.pause()
                self.isPlaying = false
            }
        }
        queue.async {
            let script: String
            switch action {
            case "toggle": script = "tell application \"\(app)\" to playpause"
            case "next": script = "tell application \"\(app)\" to next track"
            case "prev": script = "tell application \"\(app)\" to previous track"
            case "state":
                script = """
                tell application "\(app)"
                    if it is running then
                        try
                            (name of current track) & " — " & (artist of current track)
                        on error
                            "open"
                        end try
                    else
                        "closed"
                    end if
                end tell
                """
            default: return
            }
            var err: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue ?? ""
            if let c = completion, action == "state" {
                DispatchQueue.main.async { c(out) }
            }
        }
    }

    /// Seek the timeline
    func seek(to seconds: Double) {
        let s = max(0, seconds)
        if source == "YouTube Web" {
            YTWebPlayer.shared.seekWeb(to: s)
            position = s
            return
        }
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 1))
        position = s
    }

    func open(_ urlString: String) {
        if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
    }

    // MARK: Prev / next across sources (wraps around)
    func nextTrack() {
        switch source {
        case "YouTube Web":
            expectingWebPlay = true
            YTWebPlayer.shared.nextWeb()
            isPlaying = true
            RemoteCommands.refresh()
        case "Local":
            guard !localTracks.isEmpty else { return }
            playLocal(at: (localIndex + 1) % localTracks.count)
        case "YouTube":
            stepYouTube(by: 1)
        case "Spotify":
            control(app: "Spotify", action: "next")
            DispatchQueue.main.async { self.isPlaying = true; RemoteCommands.refresh() }
        case "Apple":
            control(app: "Music", action: "next")
            DispatchQueue.main.async { self.isPlaying = true; RemoteCommands.refresh() }
        default: break
        }
    }

    func prevTrack() {
        switch source {
        case "YouTube Web":
            expectingWebPlay = true
            YTWebPlayer.shared.prevWeb()
            isPlaying = true
            RemoteCommands.refresh()
        case "Local":
            guard !localTracks.isEmpty else { return }
            playLocal(at: (localIndex - 1 + localTracks.count) % localTracks.count)
        case "YouTube":
            stepYouTube(by: -1)
        case "Spotify":
            control(app: "Spotify", action: "prev")
            DispatchQueue.main.async { self.isPlaying = true; RemoteCommands.refresh() }
        case "Apple":
            control(app: "Music", action: "prev")
            DispatchQueue.main.async { self.isPlaying = true; RemoteCommands.refresh() }
        default: break
        }
    }

    private func stepYouTube(by delta: Int) {
        let r = YouTubeService.shared.results
        guard !r.isEmpty else { return }
        let count = r.count
        let i = r.firstIndex(where: { $0.id == currentAudioId })
            .map { ($0 + delta + count) % count } ?? 0
        YouTubeService.shared.play(r[i])
    }

    /// Warm the deterministic next track (repeat-all) before this one ends.
    private func preloadNext() {
        guard source == "YouTube" else { return } // local files are already instant
        let r = YouTubeService.shared.results
        guard !r.isEmpty else { return }
        let i = r.firstIndex(where: { $0.id == currentAudioId }) ?? -1
        YouTubeService.shared.prefetch(r[(i + 1) % r.count].id)
    }

    func cycleRepeat() { repeatMode = repeatMode.next() }

    /// End-of-track routing: one → replay, shuffle → random next,
    /// all → next (wrap), off → STOP. No silent auto-advance on off.
    func trackEnded() {
        defer { RemoteCommands.refresh() }
        // AV end events are meaningless while the site owns playback.
        guard source != "YouTube Web" else { return }
        switch source {
        case "Local":
            guard !localTracks.isEmpty else { isPlaying = false; return }
            if repeatMode == .one { playLocal(at: localIndex); return }
            if shuffle { playLocal(at: randomIndex(count: localTracks.count, excluding: localIndex)); return }
            if repeatMode == .all { playLocal(at: (localIndex + 1) % localTracks.count); return }
            isPlaying = false
        case "YouTube":
            let r = YouTubeService.shared.results
            guard !r.isEmpty else { isPlaying = false; return }
            if repeatMode == .one {
                if let t = r.first(where: { $0.id == currentAudioId }) { YouTubeService.shared.play(t) }
                else { isPlaying = false }
                return
            }
            if shuffle {
                let ids = r.map(\.id)
                let others = ids.indices.filter { ids[$0] != currentAudioId }
                YouTubeService.shared.play(r[others.randomElement() ?? 0])
                return
            }
            let i = r.firstIndex(where: { $0.id == currentAudioId }) ?? 0
            if repeatMode == .all { YouTubeService.shared.play(r[(i + 1) % r.count]); return }
            isPlaying = false
        default:
            isPlaying = false
        }
    }

    private func randomIndex(count: Int, excluding: Int) -> Int {
        guard count > 1 else { return 0 }
        var i = excluding
        while i == excluding { i = Int.random(in: 0..<count) }
        return i
    }
}

// MARK: - Play history (all sources, persisted, replayable)
struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    var title: String
    var source: String
    var date: Date
    var videoId: String?
    var localURL: String?
    var audioId: String?
}

final class PlayHistoryStore: ObservableObject {
    static let shared = PlayHistoryStore()
    @Published var entries: [HistoryEntry] = []
    private let key = "playHistory"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
        if let data = UserDefaults.standard.data(forKey: countsKey),
           let c = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = c
        }
    }

    func record(title: String, source: String, videoId: String? = nil, localURL: URL? = nil, audioId: String? = nil) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "Nothing playing", clean != "open", clean != "closed" else { return }
        // Play counts bump on EVERY play, even repeats
        bump(key: key(videoId: videoId, localURL: localURL, audioId: audioId, title: clean, source: source))
        // Skip consecutive duplicates in the visible list
        if entries.first?.title == clean { return }
        entries.insert(HistoryEntry(title: clean, source: source, date: Date(),
                                    videoId: videoId, localURL: localURL?.absoluteString, audioId: audioId), at: 0)
        if entries.count > 60 { entries = Array(entries.prefix(60)) }
        save()
    }

    func replay(_ e: HistoryEntry) {
        if let aid = e.audioId {
            // YouTube watch id (yt:…) or legacy open-stream id (au:…).
            let vid = aid.hasPrefix("yt:") ? String(aid.dropFirst(3)) : aid
            if aid.hasPrefix("au:"),
               let url = URL(string: "https://discoveryprovider.audius.co/v1/tracks/\(vid)/stream?app_name=NotchApp") {
                MusicService.shared.play(url: url, title: e.title, sub: "Stream", source: "YouTube", audioId: aid)
            } else {
                YouTubeService.shared.playId(vid, title: e.title)
            }
        } else if let vid = e.videoId {
            // Legacy Innertube-era entry: the id IS a YouTube watch id.
            YouTubeService.shared.playId(vid, title: e.title)
        } else if let s = e.localURL, let url = URL(string: s) {
            MusicService.shared.play(url: url, title: e.title, sub: "Local file", source: "Local", localURL: url)
        }
        // Spotify / Apple entries are remote-only — shown for reference
    }

    func clear() { entries = []; save() }

    // MARK: Times-played counts (persisted, keyed per song)
    @Published var counts: [String: Int] = [:]
    private let countsKey = "playCounts"

    func key(videoId: String? = nil, localURL: URL? = nil, audioId: String? = nil, title: String, source: String) -> String {
        if let aid = audioId { return aid.hasPrefix("yt:") || aid.hasPrefix("au:") ? aid : "yt:\(aid)" }
        if let vid = videoId { return "yt:\(vid)" }
        if let u = localURL { return "local:\(u.path)" }
        return "other:\(source):\(title)"
    }

    func bump(key: String) {
        counts[key, default: 0] += 1
        if let data = try? JSONEncoder().encode(counts) {
            UserDefaults.standard.set(data, forKey: countsKey)
        }
    }

    func plays(videoId: String? = nil, localURL: URL? = nil, audioId: String? = nil, title: String = "", source: String = "") -> Int {
        counts[key(videoId: videoId, localURL: localURL, audioId: audioId, title: title, source: source), default: 0]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
