import SwiftUI
import AppKit

// Apple-Music-style music hub: player on top, sources sidebar left, songs middle.
struct MusicHubView: View {
    @StateObject private var music = MusicService.shared
    @StateObject private var yt = YouTubeService.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var history = PlayHistoryStore.shared
    @State private var query = ""
    @State private var appTrack = ""
    @State private var scrub: Double?
    @GestureState private var sidebarDrag: CGFloat = 0
    @State private var handleHover = false

    /// Live sidebar width while dragging (committed to settings on release).
    var sidebarLiveWidth: CGFloat {
        min(300, max(110, CGFloat(settings.musicSidebarWidth) + sidebarDrag))
    }

    let sources: [(id: String, name: String, icon: String)] = [
        ("YouTube", "YouTube", "play.tv"),
        ("Spotify", "Spotify", "waveform"),
        ("Apple", "Apple", "music.note"),
        ("Local", "Local", "folder"),
        ("History", "History", "clock"),
    ]

    var hasTrack: Bool { music.title != "Nothing playing" }
    /// Embedded YT site owns its own player UI — our strip would be dead weight.
    var isSiteMode: Bool { sel == "YouTube" && settings.youTubeMode == 0 }

    /// Volume slider shared by both strip layouts.
    var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.caption).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(music.volume) },
                    set: { music.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(minWidth: 60, maxWidth: 100)
            .controlSize(.small)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    var sel: String { settings.musicTab }

    var searchPlaceholder: String {
        switch sel {
        case "Local": return "Search local songs…"
        case "History": return "Filter history…"
        default: return "Search \(sel)…"
        }
    }

    // Local list filtered by sidebar search
    var filteredLocal: [(index: Int, name: String, url: URL)] {
        let all = Array(music.localURLs.enumerated()).map { (index: $0.offset, name: $0.element.lastPathComponent, url: $0.element) }
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var filteredHistory: [HistoryEntry] {
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Player strip (Site mode hides it — the page owns that space now).
            if !isSiteMode {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        if music.isPlaying { EQBars() }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(music.title).font(.subheadline).lineLimit(1)
                            if !music.subtitle.isEmpty {
                                Text(music.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if music.source == "YouTube" && yt.resolving {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 16) {
                        Button { music.shuffle.toggle() } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.plain).font(.body)
                        .foregroundColor(music.shuffle ? .blue : .secondary)
                        .help("Shuffle")
                        .disabled(!hasTrack)
                        Button { music.prevTrack() } label: { Image(systemName: "backward.fill") }
                            .buttonStyle(.plain).font(.body)
                            .disabled(!hasTrack)
                        Button { music.toggle() } label: {
                            Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!hasTrack)
                        Button { music.nextTrack() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(.plain).font(.body)
                            .disabled(!hasTrack)
                        Button { music.cycleRepeat() } label: {
                            Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                        }
                        .buttonStyle(.plain).font(.body)
                        .foregroundColor(music.repeatMode == .off ? .secondary : .blue)
                        .help(music.repeatMode == .off ? "Repeat: off" : music.repeatMode == .all ? "Repeat: all" : "Repeat: one")
                        .disabled(!hasTrack)
                    }
                    volumeControl
                    }
                    // Timeline below the transport
                    HStack(spacing: 8) {
                        Text(fmtTime(scrub ?? music.position))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading).monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { scrub ?? min(music.position, max(music.trackLength, 0)) },
                                set: { scrub = $0 }
                            ),
                            in: 0...max(music.trackLength, 1),
                            onEditingChanged: { editing in
                                if !editing {
                                    if let v = scrub { music.seek(to: v) }
                                    scrub = nil
                                }
                            }
                        )
                        .controlSize(.mini)
                        .disabled(music.trackLength <= 0)
                        Text(fmtTime(music.trackLength))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing).monospacedDigit()
                    }
                }
                .padding(10).background(.ultraThinMaterial).cornerRadius(12)
            }

            // Sidebar + songs (hidden in Site mode — the page takes everything)
            HStack(alignment: .top, spacing: 0) {
                // Left: search on top of sources
                if !isSiteMode, !settings.musicSidebarCollapsed {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                        TextField(searchPlaceholder, text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runSearch() }
                            .onChange(of: query) { _, v in yt.suggestDebounced(v) }
                        Button(yt.searching && sel == "YouTube" && settings.youTubeMode == 1 ? "…" : "Go") { runSearch() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(yt.searching && sel == "YouTube" && settings.youTubeMode == 1)
                        }
                        ForEach(sources, id: \.id) { s in
                            HStack(spacing: 8) {
                                Image(systemName: s.icon).frame(width: 16).foregroundStyle(sel == s.id ? .primary : .secondary)
                                Text(s.name).font(.callout).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(sel == s.id ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .onTapGesture { settings.musicTab = s.id }
                        }
                        Spacer()
                    }
                    .frame(width: sidebarLiveWidth)
                    // Drag must track the mouse 1:1 — never ease it.
                    .animation(nil, value: sidebarDrag)

                    // Draggable divider: grab to resize the sidebar (persists on release)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 11)
                        .contentShape(Rectangle())
                        .overlay(
                            HStack(spacing: 0) {
                                Divider()
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(handleHover ? 0.4 : 0.0))
                                    .frame(width: 4)
                                    .padding(.vertical, 24)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 2)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .updating($sidebarDrag) { v, state, _ in state = v.translation.width }
                                .onEnded { v in
                                    settings.musicSidebarWidth = Double(min(300, max(110, CGFloat(settings.musicSidebarWidth) + v.translation.width)))
                                }
                        )
                        .onHover { h in handleHover = h }
                        // Native cursor rect (not push/pop, which AppKit resets on
                        // mouse-move): guarantees ↔ whenever the mouse is over us.
                        .background(ResizeCursorView())
                }

                // Slim leading toggle column — visible in both states (not Site: no room spared)
                if !isSiteMode {
                    VStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { settings.musicSidebarCollapsed.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(settings.musicSidebarCollapsed ? "Show sources sidebar" : "Hide sources sidebar")
                    Spacer()
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 2)
                }

                // Middle: songs for the selected source
                Group {
                    switch sel {
                    case "YouTube": ytList
                                        case "Spotify": spotifyView
                    case "Apple": appleView
                    case "History": historyView
                    default: localList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    func runSearch() {
        switch sel {
        case "YouTube":
            if settings.youTubeMode == 1 { yt.search(query) } else { YTWebPlayer.shared.search(query) }
        case "Spotify": music.open("https://open.spotify.com/search/\(encoded(query))")
        case "Apple": music.open("https://music.apple.com/search?term=\(encoded(query))")
        default: break // Local + History filter live
        }
    }

    // MARK: YouTube — List (fast names, in-notch audio) or Site (embedded web, full-bleed)
    var ytList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if settings.youTubeMode == 0 {
                    // Sidebar is hidden in full-bleed: this is the way back out.
                    Button {
                        settings.musicSidebarCollapsed = false
                        settings.youTubeMode = 1
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Back to sources")
                }
                Picker("", selection: $settings.youTubeMode) {
                    Text("Site").tag(0)
                    Text("List").tag(1)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 220)
                if settings.youTubeMode == 0 {
                    Button { YTWebPlayer.shared.goBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).font(.body)
                    Button { YTWebPlayer.shared.goForward() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).font(.body)
                    Button { YTWebPlayer.shared.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).font(.body)
                    Button { YTWebPlayer.shared.openHome() } label: { Image(systemName: "house") }
                        .buttonStyle(.plain).font(.body)
                    Spacer()
                    volumeControl
                        .frame(width: 150)
                } else {
                    Spacer()
                }
            }
            .foregroundStyle(.secondary)
            if settings.youTubeMode == 0 {
                YTWebHost()
                    .cornerRadius(10)
                    .frame(maxHeight: .infinity)
            } else {
                ytResultsList
            }
        }
    }

    // MARK: YouTube names list (fast search, tap to play here)
    var ytResultsList: some View {
        VStack(spacing: 6) {
            // Type-ahead suggestions live where songs appear.
            if !query.isEmpty, query != yt.lastQuery, !yt.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(yt.suggestions, id: \.self) { s in
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                            Text(s).font(.caption).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { query = s; runSearch() }
                        Divider()
                    }
                }
                .background(Color.white.opacity(0.05)).cornerRadius(8)
            }
            if yt.searching && yt.results.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if yt.failed && yt.results.isEmpty {
                Text("Couldn't reach YouTube — check connection and Go again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !yt.searching && !yt.failed && yt.results.isEmpty && yt.suggestions.isEmpty {
                // Empty list: search button right here so the pane is never a dead box.
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Type above and hit Search" : "No songs found — try another search")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Search") { runSearch() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            List(yt.results) { t in
                HStack(spacing: 8) {
                    if let url = URL(string: t.thumb), !t.thumb.isEmpty {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .cornerRadius(8)
                    } else {
                        Button { yt.play(t) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.plain).font(.body)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.title).font(.caption).lineLimit(1)
                        if !t.artist.isEmpty {
                            Text(t.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if t.duration > 0 {
                        Text(fmtTime(t.duration)).font(.caption2).foregroundStyle(.secondary)
                    }
                    let c = history.plays(audioId: "yt:\(t.id)")
                    if c > 0 { Text("×\(c)").font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture { yt.play(t) }
                .onHover { hovering in if hovering { yt.prefetch(t.id) } }
            }.listStyle(.plain).frame(maxHeight: .infinity)
        }
    }

    /// Hosts the shared persistent YT webview: attaches on appear, parks on disappear.
    struct YTWebHost: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            v.wantsLayer = true
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) {
            YTWebPlayer.shared.attach(to: nsView)
        }
        static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
            YTWebPlayer.shared.detach()
        }
    }

    // MARK: Spotify / Apple remote
    var spotifyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appTrack.isEmpty {
                Text(appTrack).font(.callout).lineLimit(2)
            }
            if music.isAppInstalled("Spotify") {
                HStack {
                    Button { remote("Spotify", "prev") } label: { Image(systemName: "backward.fill") }
                    Button { remote("Spotify", "toggle") } label: { Image(systemName: "playpause.fill") }.buttonStyle(.borderedProminent)
                    Button { remote("Spotify", "next") } label: { Image(systemName: "forward.fill") }
                    Spacer()
                    Button("Refresh") { fetchTrack("Spotify") }.controlSize(.small)
                }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Text("Spotify isn't installed on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onAppear { fetchTrack("Spotify") }
    }

    var appleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appTrack.isEmpty {
                Text(appTrack).font(.callout).lineLimit(2)
            }
            if music.isAppInstalled("Music") {
                HStack {
                    Button { remote("Music", "prev") } label: { Image(systemName: "backward.fill") }
                    Button { remote("Music", "toggle") } label: { Image(systemName: "playpause.fill") }.buttonStyle(.borderedProminent)
                    Button { remote("Music", "next") } label: { Image(systemName: "forward.fill") }
                    Spacer()
                    Button("Refresh") { fetchTrack("Music") }.controlSize(.small)
                }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Text("Apple Music isn't installed on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onAppear { fetchTrack("Music") }
    }

    func remote(_ app: String, _ action: String) {
        music.control(app: app, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { fetchTrack(app, markPlaying: true) }
    }

    func fetchTrack(_ app: String, markPlaying: Bool = false) {
        let src = app == "Music" ? "Apple" : app
        music.control(app: app, action: "state") { name in
            appTrack = name
            history.record(title: name, source: src)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "open", trimmed != "closed" else { return }
            // AppleScript returns "Track — Artist"; accept common dash variants.
            var track = trimmed
            var artist = ""
            for sep in [" — ", " – ", " - "] {
                if let r = trimmed.range(of: sep) {
                    let t = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let a = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { track = t; artist = a }
                    break
                }
            }
            // Publish to the top strip; never touches AVPlayer/player.
            music.title = track
            music.subtitle = artist
            music.source = src
            music.trackLength = 0
            music.position = 0
            if markPlaying { music.isPlaying = true }
            RemoteCommands.refresh()
        }
    }

    // MARK: Local library
    var localList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Invisible play icon keeps TITLE aligned with the song rows below.
                Image(systemName: "play.circle").font(.body).opacity(0)
                Text("TITLE").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("TIME").font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Text("PLAYS").font(.caption2).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                Button("Import…") { music.pickLocalFiles() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 4)
            List(filteredLocal, id: \.index) { item in
                HStack(spacing: 8) {
                    Button { music.playLocal(at: item.index) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.plain).font(.body)
                    Text(item.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(music.durationText(item.url) ?? "–")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    let c = history.plays(localURL: item.url)
                    Text(c > 0 ? "×\(c)" : "–")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { music.playLocal(at: item.index) }
            }.listStyle(.plain).frame(maxHeight: .infinity)
        }
    }

    // MARK: History
    var historyView: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(filteredHistory.count) played").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { history.clear() }.controlSize(.small)
            }
            List(filteredHistory) { e in
                HStack(spacing: 8) {
                    if e.audioId != nil || e.localURL != nil {
                        Button { history.replay(e) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).font(.body)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.caption).lineLimit(1)
                        Text("\(e.source) · \(history.ago(e.date))").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let c = history.plays(videoId: e.videoId, localURL: e.localURL.flatMap { URL(string: $0) }, audioId: e.audioId, title: e.title, source: e.source)
                    if c > 1 { Text("×\(c)").font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture { history.replay(e) }
            }.listStyle(.plain).frame(maxHeight: .infinity)
        }
    }

    func encoded(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }

    func fmtTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return "\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))"
    }
}

// MARK: Native ↔ cursor rect for the sidebar drag handle.
final class ResizeCursorRectView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

struct ResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeCursorRectView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.discardCursorRects()
    }
}

// MARK: Playing indicator — animated bars only while audio plays
struct EQBars: View {
    @State private var on = false
    private let tall: [CGFloat] = [11, 17, 7, 13]
    private let short: [CGFloat] = [4, 6, 4, 5]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green)
                    .frame(width: 3, height: on ? tall[i] : short[i])
                    .animation(
                        .easeInOut(duration: 0.38).repeatForever(autoreverses: true).delay(Double(i) * 0.11),
                        value: on
                    )
            }
        }
        .frame(height: 17, alignment: .bottom)
        .onAppear { on = true }
    }
}
