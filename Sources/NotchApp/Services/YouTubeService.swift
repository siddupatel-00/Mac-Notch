import Foundation
import Combine

/// Full YouTube catalogue, played in-notch: vendored yt-dlp resolves direct
/// audio streams, AVPlayer plays them like local files. No keys, no webviews.
struct YTEntry: Identifiable {
    let id: String   // 11-char videoId
    var title: String
    var artist: String
    var duration: Double
    var thumb: String = ""
}

/// Main-thread UI writes + locked cache make cross-queue use safe.
/// (Needed for GCD/Task closures; DO NOT REMOVE.)
final class YouTubeService: ObservableObject, @unchecked Sendable {
    static let shared = YouTubeService()

    @Published var results: [YTEntry] = []
    @Published var searching = false
    @Published var failed = false
    @Published var resolving = false
    @Published var suggestions: [String] = []
    private(set) var lastQuery = ""
    private var suggestTask: Task<Void, Never>?
    private var suggestQuery = ""

    /// Single-lane resolve scheduler. At most ONE yt-dlp process exists at any
    /// moment; newer taps terminate older work. Pileups are structurally impossible.
    private let lane = DispatchQueue(label: "yt.resolve")
    private let genLock = NSLock()
    private var playGen = 0
    private var prefetchGen = 0
    private var activeProc: Process?

    private func bumpPlayGen() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        playGen += 1; prefetchGen += 1
        return playGen
    }
    private func isPlayCurrent(_ g: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return g == playGen
    }
    private func bumpPrefetchGen() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        prefetchGen += 1
        return prefetchGen
    }
    private func isPrefetchCurrent(_ g: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return g == prefetchGen
    }
    private func terminateActive() {
        genLock.lock()
        let t = activeProc
        activeProc = nil
        genLock.unlock()
        t?.terminate()
    }

    /// Resolved stream URLs live ~6h and are IP-bound (same machine = reusable).
    /// Memory + disk cache makes replays / repeat-one / prev-next instant.
    private var urlCache: [String: (url: String, at: Date)] = [:]
    private let cacheKey = "ytStreamCache"
    private let cacheLock = NSLock()

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let dict = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            let now = Date()
            for (id, e) in dict where now.timeIntervalSince(e.at) < 5 * 3600 {
                urlCache[id] = (e.url, e.at)
            }
        }
    }

    private struct CacheEntry: Codable { var url: String; var at: Date }

    private func cachedURL(_ id: String) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let c = urlCache[id],
              Date().timeIntervalSince(c.at) < 5 * 3600,
              let url = URL(string: c.url) else { return nil }
        return url
    }

    private func storeURL(_ id: String, _ url: URL) {
        cacheLock.lock()
        urlCache[id] = (url.absoluteString, Date())
        let dict = urlCache.mapValues { CacheEntry(url: $0.url, at: $0.at) }
        cacheLock.unlock()
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// yt-dlp binary bundled in Resources (falls back to a vendor path for dev runs).
    static var binaryURL: URL? {
        if let u = Bundle.main.url(forResource: "yt-dlp", withExtension: nil) { return u }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/OpenCode/notch-app/Resources/yt-dlp")
    }

    /// Run the binary, capture stdout, enforce a timeout. The process registers
    /// itself so a newer tap can terminate it mid-flight.
    private func launch(_ args: [String], timeout: TimeInterval) -> String? {
        guard let bin = Self.binaryURL,
              FileManager.default.isExecutableFile(atPath: bin.path) else { return nil }
        let task = Process()
        task.executableURL = bin
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        genLock.lock()
        activeProc = task
        genLock.unlock()
        defer {
            genLock.lock()
            if activeProc === task { activeProc = nil }
            genLock.unlock()
        }
        do { try task.run() } catch { return nil }
        let box = LockedBox<String?>(nil)
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.value = String(data: data, encoding: .utf8)
            g.leave()
        }
        if g.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            return nil
        }
        let out = box.value ?? ""
        return out.isEmpty ? nil : out
    }

    /// Recent searches: repeat queries return instantly.
    private var searchCache: [String: [YTEntry]] = [:]

    func search(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        lastQuery = query
        suggestions = []
        _ = bumpPrefetchGen() // new search invalidates older queued prefetches (not playback)
        if let hit = searchCache[query.lowercased()], !hit.isEmpty {
            searching = false
            failed = false
            results = hit
            return
        }
        searching = true
        failed = false
        // Fast path: YouTube's own search API (~1s). yt-dlp stays out of this —
        // it only resolves audio when you tap play.
        Task {
            do {
                let tracks = try await Innertube.search(query)
                let entries = tracks.map {
                    YTEntry(id: $0.id, title: $0.title, artist: $0.artist, duration: $0.durationSecs, thumb: $0.thumb)
                }
                await MainActor.run {
                    self.searching = false
                    self.results = entries
                    self.failed = entries.isEmpty
                }
                if !entries.isEmpty {
                    self.searchCache[query.lowercased()] = entries
                }
                // Prefetch the top 6 streams through the single lane (stale ones
                // evaporate via generation check): tapping any then plays instantly.
                let tops = Array(entries.prefix(6).filter { self.cachedURL($0.id) == nil })
                let pg = self.bumpPrefetchGen()
                for t in tops {
                    self.lane.async { [weak self] in
                        guard let self, self.isPrefetchCurrent(pg), self.cachedURL(t.id) == nil else { return }
                        if let url = self.resolveURL(t.id) { self.storeURL(t.id, url) }
                    }
                }
            } catch {
                await MainActor.run { self.searching = false; self.failed = true }
            }
        }
    }

    /// Type-ahead suggestions (YouTube suggest API, no key). Debounced; safe to
    /// call on every keystroke — only the latest query fires.
    func suggestDebounced(_ q: String) {
        suggestTask?.cancel()
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestQuery = query
        guard query.count >= 2, query != lastQuery else {
            if query.isEmpty { suggestions = [] }
            return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let list = (try? await fetchSuggestions(query)) ?? []
            await MainActor.run {
                if self.suggestQuery == query { self.suggestions = list }
            }
        }
    }

    private func fetchSuggestions(_ query: String) async throws -> [String] {
        guard let eq = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries.google.com/complete/search?client=youtube&ds=yt&q=\(eq)") else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2 else { return [] }
        // Shape: ["q", [["sug",…],…], …] — accept plain strings too.
        guard let arr = json[1] as? [Any] else { return [] }
        return arr.prefix(8).compactMap {
            if let s = $0 as? String { return s }
            if let a = $0 as? [Any], let s = a.first as? String { return s }
            return nil
        }.filter { !$0.isEmpty }
    }
    /// DO NOT REMOVE — referenced from MusicHub row hover.
    func prefetch(_ id: String) {
        guard cachedURL(id) == nil else { return }
        let pg = bumpPrefetchGen()
        lane.async { [weak self] in
            guard let self, self.isPrefetchCurrent(pg), self.cachedURL(id) == nil else { return }
            if let url = self.resolveURL(id) { self.storeURL(id, url) }
        }
    }

    /// Direct audio URL, cached (fast path) or freshly resolved.
    /// player_client=android skips the web client's slow PO-token handshake.
    private func resolveURL(_ id: String) -> URL? {
        if let cached = cachedURL(id) { return cached }
        guard let out = launch([
            "-g", "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "--no-playlist", "--no-warnings",
            "--socket-timeout", "8", "--retries", "2",
            "--extractor-args", "youtube:player_client=android",
            "https://www.youtube.com/watch?v=\(id)",
        ], timeout: 45),
        let first = out.components(separatedBy: "\n").first(where: { $0.hasPrefix("http") }),
              let url = URL(string: first.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        storeURL(id, url)
        return url
    }

    /// Resolve a watch id to a direct audio URL, then play it.
    func play(_ e: YTEntry) {
        playId(e.id, title: e.title, artist: e.artist, duration: e.duration)
    }

    func playId(_ id: String, title: String, artist: String = "", duration: Double = 0) {
        // Cache hit = instant play, no resolve wait.
        if let url = cachedURL(id) {
            MusicService.shared.currentAudioId = id
            MusicService.shared.play(url: url, title: title,
                                     sub: artist.isEmpty ? "YouTube" : artist,
                                     source: "YouTube", audioId: "yt:\(id)")
            if duration > 0 { MusicService.shared.trackLength = duration }
            return
        }
        // Stop the old song FIRST: otherwise its audio keeps playing under the
        // new title while we resolve (ghost playback). Then take the single lane:
        // TERMINATE anything still resolving, so this tap owns the one process.
        let gen = bumpPlayGen()
        terminateActive()
        DispatchQueue.main.async {
            MusicService.shared.stopAppPlayback()
            MusicService.shared.title = title
            MusicService.shared.subtitle = "Resolving audio…"
            MusicService.shared.source = "YouTube"
            MusicService.shared.position = 0
            MusicService.shared.trackLength = duration
            self.resolving = true
        }
        lane.async { [weak self] in
            guard let self, self.isPlayCurrent(gen) else { return }
            let url = self.resolveURL(id)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlayCurrent(gen) else { return }
                self.resolving = false
                guard let url else {
                    MusicService.shared.subtitle = "Couldn't resolve — try another"
                    return
                }
                MusicService.shared.currentAudioId = id
                MusicService.shared.play(url: url, title: title,
                                         sub: artist.isEmpty ? "YouTube" : artist,
                                         source: "YouTube", audioId: "yt:\(id)")
                if duration > 0 { MusicService.shared.trackLength = duration }
            }
        }
    }
}

/// Tiny synchronized box for passing Process output across queues.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
