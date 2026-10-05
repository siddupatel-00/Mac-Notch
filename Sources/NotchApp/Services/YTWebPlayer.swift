import Foundation
import WebKit
import AppKit
import Combine

/// The real music.youtube.com embedded in the notch.
/// One retained WKWebView that lives on after tab switches: the tab only
/// BORROWS it (reparent on appear/disappear), so playback survives closing
/// the notch. AV playback pauses the site and vice versa — one source at a time.
///
/// The top strip drives the site through the helpers below, and the 2s poll
/// adopts site playback into MusicService (source "YouTube Web") so the
/// strip, timeline, volume and media keys all follow it.
final class YTWebPlayer: NSObject, ObservableObject {
    static let shared = YTWebPlayer()

    @Published var webIsPlaying = false

    private var web: WKWebView?
    private var holder: NSView?
    private var holderPanel: NSPanel?
    private var poll: Timer?
    private var loadedOnce = false
    private var lastWebTitle = ""

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 8, height: 8), configuration: cfg)
        // YT Music refuses the default WebKit UA ("not optimised for your browser").
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        // The site's layout is wider than the notch panel — zoom out so it all fits.
        w.pageZoom = 0.72
        web = w
        // Parking spot: 2px on-screen corner (offscreen windows get suspended).
        let hold = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        holder = hold
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        hold.addSubview(w)
        w.autoresizingMask = [.width, .height]
        panel.contentView = hold
        holderPanel = panel // RETAINED
        panel.orderFrontRegardless()
        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let p = poll { RunLoop.main.add(p, forMode: .common) }
    }

    // MARK: - Tab borrowing

    /// Move the live view into the tab. Call on appear.
    func attach(to parent: NSView) {
        guard let w = web, w.superview !== parent else { return }
        w.removeFromSuperview()
        w.frame = parent.bounds
        w.autoresizingMask = [.width, .height]
        parent.addSubview(w)
        ensureLoaded()
    }

    /// Park it back off-tab. Call on disappear — audio keeps going.
    func detach() {
        guard let w = web, let hold = holder, w.superview !== hold else { return }
        w.removeFromSuperview()
        w.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
        w.autoresizingMask = []
        hold.addSubview(w)
    }

    private func ensureLoaded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        web?.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    func openHome() {
        web?.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    func search(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let eq = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.youtube.com/search?q=\(eq)") else { return }
        ensureLoaded()
        web?.load(URLRequest(url: url))
    }

    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }
    func reload() { web?.reload() }

    // MARK: - Strip controls (drive the site)

    /// Silence the site (called when AV starts).
    func pauseWeb() {
        web?.evaluateJavaScript("(()=>{const v=document.querySelector('video');if(v)v.pause();})()", completionHandler: nil)
    }

    /// Toggle play/pause on the site. Prefer the player-bar button (keeps the
    /// site's own UI in sync); fall back to the raw video element.
    func toggleWeb() {
        web?.evaluateJavaScript("""
        (()=>{
          const b=document.querySelector('ytmusic-player-bar #play-pause-button');
          if(b){b.click();return;}
          const v=document.querySelector('video');
          if(v){ if(v.paused)v.play(); else v.pause(); }
        })()
        """, completionHandler: nil)
    }

    func nextWeb() {
        web?.evaluateJavaScript("""
        (()=>{
          const n=document.querySelector('ytmusic-player-bar .next-button');
          if(n){n.click();}
        })()
        """, completionHandler: nil)
    }

    func prevWeb() {
        web?.evaluateJavaScript("""
        (()=>{
          const p=document.querySelector('ytmusic-player-bar .previous-button');
          if(p){p.click();}
        })()
        """, completionHandler: nil)
    }

    func setWebVolume(_ v: Float) {
        let c = min(1, max(0, v))
        web?.evaluateJavaScript("(()=>{const v=document.querySelector('video');if(v){v.volume=\(c);v.muted=\(c <= 0 ? "true" : "false");}})()", completionHandler: nil)
    }

    func seekWeb(to seconds: Double) {
        let s = max(0, seconds)
        web?.evaluateJavaScript("(()=>{const v=document.querySelector('video');if(v&&isFinite(v.duration))v.currentTime=Math.min(\(s),v.duration);})()", completionHandler: nil)
    }

    // MARK: - Adopt site playback into the strip

    /// Watch the site: while IT plays, adopt it as the current source so the top
    /// strip, timeline, volume and media keys all follow it. One source at a time.
    private func tick() {
        web?.evaluateJavaScript("""
        (()=>{
          const v=document.querySelector('video');
          if(!v)return 'none';
          const t=(s)=>((s||'').trim());
          const bar=document.querySelector('ytmusic-player-bar');
          const title=t(bar?.querySelector('.title')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ')[0]);
          const artist=t(bar?.querySelector('.byline')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ').slice(1).join(' - '));
          return JSON.stringify({p:!!v.paused,t:v.currentTime||0,d:v.duration||0,title:title,artist:artist});
        })()
        """) { [weak self] res, _ in
            guard let self,
                  let s = res as? String, s != "none",
                  let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let paused = (j["p"] as? Bool) ?? true
            let t = (j["t"] as? Double) ?? 0
            let dur = (j["d"] as? Double) ?? 0
            let title = ((j["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = ((j["artist"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let playing = !paused && t > 0
            DispatchQueue.main.async {
                self.webIsPlaying = playing
                let m = MusicService.shared
                if playing {
                    if m.isPlaying && m.source != "YouTube Web" { m.pause() }
                    m.silenceExternalApps()
                    m.source = "YouTube Web"
                    if !title.isEmpty { m.title = title }
                    m.subtitle = artist.isEmpty ? "YouTube Music" : artist
                    m.position = t
                    if dur.isFinite, dur > 0 { m.trackLength = dur }
                    if !m.isPlaying { m.isPlaying = true }
                    if !title.isEmpty, title != self.lastWebTitle {
                        self.lastWebTitle = title
                        PlayHistoryStore.shared.record(title: title, source: "YouTube Web")
                    }
                    RemoteCommands.refresh()
                } else if m.source == "YouTube Web" {
                    if m.isPlaying { m.isPlaying = false }
                    RemoteCommands.refresh()
                }
            }
        }
    }
}
