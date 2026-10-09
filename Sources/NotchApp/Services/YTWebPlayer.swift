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
    // Ad handling: muted-by-us flag + last user volume (to restore after ads).
    private var inAd = false
    private var adMutedByUs = false
    private var lastVolume: Float = 0.8
    // Watchdog counters: consecutive ad-positive ticks, and consecutive muted ticks.
    private var adStreak = 0
    private var mutedStreak = 0
    // Paused-while-expected counter: unexpected stalls get resumed, deliberate
    // user pauses (expectingWebPlay == false) are never touched.
    private var pausedStreak = 0

    /// Flight recorder: timestamped player/ad decisions for diagnosing kills.
    /// Read at ~/Library/Logs/NotchApp/ytweb.log. Rotates at ~200KB.
    private override init() {
        super.init()
        setup()
    }

    /// Runtime bisection switches (set with `defaults write com.local.notchapp <key> -bool`):
    /// - ytNoAdPatch  : skip the youtubei response patching
    /// - ytNoAdBlock  : skip the content-rule list entirely
    static var debugNoAdPatch: Bool { UserDefaults.standard.bool(forKey: "ytNoAdPatch") }
    static var debugNoAdBlock: Bool { UserDefaults.standard.bool(forKey: "ytNoAdBlock") }

    private func setup() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // NOTE: no CSS that hides the player's <video> on purpose. YouTube's
        // web player STOPS loading when its video element is display:none or
        // zero-sized (that caused songs to freeze). Playback reliability
        // always wins over the audio-only cosmetic.
        // Response patching (the layer real YouTube adblockers use): neuter ad
        // scheduling inside youtubei player/next responses BEFORE the player
        // ever sees an ad. Runs at document start, main frame only.
        if !Self.debugNoAdPatch {
            cfg.userContentController.addUserScript(WKUserScript(
                source: Self.adPatchScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        // Aggressive ad/tracker blocking at the network layer. Compiles async;
        // if the page beats it, we reload once so rules apply to everything.
        if !Self.debugNoAdBlock {
            Self.applyAdBlock(to: cfg.userContentController) { [weak self] in
                guard let self, let w = self.web, w.url != nil else { return }
                w.reload()
            }
        }
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 8, height: 8), configuration: cfg)
        w.navigationDelegate = self
        // YT Music refuses the default WebKit UA ("not optimised for your browser").
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        // The site's layout is wider than the notch panel — zoom out so it all fits.
        w.pageZoom = 0.72
        web = w
        // Parking spot: a REAL-SIZED transparent, click-through window.
        // WebKit suspends media loading for a webview whose window is
        // occluded/invisible — the old 2×2 window at (0,0) sat under the Dock,
        // so after the initial buffer drained (~40-90s) every song starved
        // while still reporting paused=false. A full-size clear window that is
        // actually rendered (just invisible to the user) keeps the page live.
        let parkSize = NSSize(width: 760, height: 460)
        let parkFrame: NSRect
        if let screen = NSScreen.main {
            parkFrame = NSRect(x: screen.frame.midX - parkSize.width / 2,
                              y: screen.frame.maxY - parkSize.height,
                              width: parkSize.width, height: parkSize.height)
        } else {
            parkFrame = NSRect(origin: .zero, size: parkSize)
        }
        let panel = NSPanel(contentRect: parkFrame,
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Same level as the notch panel so it is never hidden behind the
        // menu bar / Dock (both of which would re-introduce the occlusion).
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let hold = NSView(frame: NSRect(origin: .zero, size: parkSize))
        hold.wantsLayer = true
        hold.layer?.backgroundColor = NSColor.clear.cgColor
        holder = hold
        hold.addSubview(w)
        w.frame = hold.bounds
        w.autoresizingMask = [.width, .height]
        panel.contentView = hold
        holderPanel = panel // RETAINED
        panel.orderFrontRegardless()
        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let p = poll { RunLoop.main.add(p, forMode: .common) }
    }

    // MARK: - Response patching (kills ads before they schedule)

    /// Patches YouTube responses in-page so ads never schedule: recursive strip
    /// of adPlacements/playerAds at ANY depth, hooked into (a) inline initial
    /// page data (watch loads bake ads in before any fetch happens), (b) fetch,
    /// (c) XHR — for every /youtubei/v1/ endpoint. Same technique as established
    /// open-source YouTube adblock userscripts. Defensive by design: anything
    /// unparseable passes through untouched, and media URLs are never modified.
    static let adPatchScript = """
    (function(){
      function stripDeep(o,depth){
        try{
          if(!o||typeof o!=='object'||depth>14)return o;
          if(Array.isArray(o)){for(var i=0;i<o.length;i++)o[i]=stripDeep(o[i],depth+1);return o;}
          if(Array.isArray(o.adPlacements))o.adPlacements=[];
          if(Array.isArray(o.playerAds))o.playerAds=[];
          if(Array.isArray(o.adSlots))o.adSlots=[];
          if('no_ads' in o){try{delete o.no_ads;}catch(e){}}
          for(var k in o){if(Object.prototype.hasOwnProperty.call(o,k)){try{o[k]=stripDeep(o[k],depth+1);}catch(e){}}}
        }catch(e){}
        return o;
      }
      // Belt and suspenders with stripDeep: rename the keys in raw text (like
      // uBO's trusted-rpfr) so even a missed nesting level can't schedule.
      function renameKeys(txt){
        return txt.split('"adPlacements"').join('"no_ads"').split('"adSlots"').join('"no_ads"');
      }
      function hookGlobal(name){
        try{
          var cur;
          try{cur=window[name];}catch(e){cur=null;}
          if(cur)stripDeep(cur,0);
          Object.defineProperty(window,name,{
            configurable:true,
            get:function(){return cur;},
            set:function(v){cur=stripDeep(v,0);}
          });
        }catch(e){}
      }
      hookGlobal('ytInitialPlayerResponse');
      hookGlobal('ytInitialData');
      function patchURL(u){return typeof u==='string'&&(u.indexOf('/youtubei/v1/')!==-1||u.indexOf('get_watch')!==-1||u.indexOf('/watch?')!==-1||u.indexOf('playlist?')!==-1);}
      try{
        var origFetch=window.fetch;
        window.fetch=function(){
          var u=arguments[0]?(arguments[0].url||arguments[0]):'';
          if(!patchURL(u))return origFetch.apply(this,arguments);
          return origFetch.apply(this,arguments).then(function(res){
            var ct='';try{ct=res.headers.get('content-type')||'';}catch(e){}
            if(ct.indexOf('json')===-1)return res;
            return res.clone().text().then(function(txt){
              try{
                var json=JSON.parse(renameKeys(txt.slice(txt.indexOf('{'))));
                stripDeep(json,0);
                return new Response(JSON.stringify(json),{status:res.status,statusText:res.statusText,headers:res.headers});
              }catch(e){return res;}
            },function(){return res;});
          });
        };
      }catch(e){}
      try{
        var origOpen=XMLHttpRequest.prototype.open;
        var origSend=XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open=function(m,u){this.__notchAdUrl=u;return origOpen.apply(this,arguments);};
        XMLHttpRequest.prototype.send=function(){
          var selfXhr=this;
          if(patchURL(selfXhr.__notchAdUrl)){
            var prev=selfXhr.onreadystatechange;
            selfXhr.onreadystatechange=function(){
              if(selfXhr.readyState===4){
                try{
                  var txt=selfXhr.responseText;
                  var json=JSON.parse(renameKeys(txt.slice(txt.indexOf('{'))));
                  stripDeep(json,0);
                  var out=JSON.stringify(json);
                  Object.defineProperty(selfXhr,'responseText',{value:out,configurable:true});
                  Object.defineProperty(selfXhr,'response',{value:out,configurable:true});
                }catch(e){}
              }
              if(prev)prev.apply(this,arguments);
            };
          }
          return origSend.apply(this,arguments);
        };
      }catch(e){}
    })();
    """

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
        w.frame = hold.bounds
        w.autoresizingMask = [.width, .height]
        hold.addSubview(w)
        // Re-assert on-screen ordering: an unoccluded park window is what keeps
        // media buffering alive while the tab is closed.
        holderPanel?.orderFrontRegardless()
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
    //
    // NOTE: music.youtube.com hosts MULTIPLE <video> elements (previews,
    // miniplayer, main player). Every snippet below MUST use __nv() — the
    // audible/playing element — never a bare querySelector('video'), or we
    // mute/pause a hidden element while the ad keeps blaring.

    /// Shared picker, installed idempotently into the page on every call.
    private static let pickJS = """
    window.__nv=window.__nv||function(){
      const all=[...document.querySelectorAll('video')];
      const main=document.querySelector('#movie_player video');
      if(main&&!main.paused&&main.currentTime>0)return main;
      const live=all.find(x=>!x.paused&&x.currentTime>0)||all.find(x=>x.readyState>0);
      return live||main||all[0]||null;
    };
    """

    /// Silence the site (called when AV starts).
    func pauseWeb() {
        web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v)v.pause();})()", completionHandler: nil)
    }

    /// Toggle play/pause on the site. Prefer the player-bar button (keeps the
    /// site's own UI in sync); fall back to the raw video element.
    func toggleWeb() {
        web?.evaluateJavaScript("""
        (()=>{
          \(Self.pickJS)
          const b=document.querySelector('ytmusic-player-bar #play-pause-button');
          if(b){b.click();return;}
          const v=window.__nv();
          if(v){ if(v.paused)v.play(); else v.pause(); }
        })()
        """, completionHandler: nil)
    }

    /// Play-only (never toggles off). Used by media-key resume and the
    /// expectingWebPlay watchdog — resume() must not pause an already-playing site.
    func playWeb() {
        web?.evaluateJavaScript("""
        (()=>{
          \(Self.pickJS)
          const v=window.__nv();
          // If the site's own button shows "play" (i.e. paused), click it so the
          // site UI stays in sync; otherwise drive the element directly.
          try{
            const b=document.querySelector('ytmusic-player-bar #play-pause-button');
            const label=((b&&(b.getAttribute('aria-label')||b.title||''))||'').toLowerCase();
            if(b&&(label.indexOf('play')!==-1)&&v&&v.paused){b.click();return;}
          }catch(e){}
          if(v&&v.paused){try{v.play();}catch(e){}}
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
        lastVolume = c
        // Never let a volume drag unmute a running ad.
        let muted = (c <= 0 || inAd) ? "true" : "false"
        web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v){v.volume=\(c);v.muted=\(muted);}})()", completionHandler: nil)
    }

    func seekWeb(to seconds: Double) {
        let s = max(0, seconds)
        web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v&&isFinite(v.duration))v.currentTime=Math.min(\(s),v.duration);})()", completionHandler: nil)
    }

    // MARK: - Adopt site playback into the strip

    /// Watch the site: while IT plays, adopt it as the current source so the top
    /// strip, timeline, volume and media keys all follow it. One source at a time.
    /// Ads (`.ad-showing`) are muted + skip-clicked here and NEVER adopted into
    /// the strip, history, or timeline.
    // Stall / death tracking for the watchdog below.
    private var lastAdvanceT: Double = -1
    private var frozenTicks = 0
    private var deadTicks = 0
    private var lastPlayURL: URL?
    private var resumeAfterLoad = false
    // Heartbeat counter: one STATE line every ~30s so playback can be verified.
    private var hbTicks = 0

    private func alog(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchApp", isDirectory: true)
            .appendingPathComponent("ytweb.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
               size > 200_000 {
                try "".write(to: url, atomically: true, encoding: .utf8)
            }
            // FileHandle(forWritingTo:) does NOT create a missing file — create it first.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            if #available(macOS 10.15, *) {
                try h.seekToEnd()
            } else {
                h.seekToEndOfFile()
            }
            try h.write(contentsOf: Data("[\(Date())] \(msg)\n".utf8))
        } catch {
            // Logging must never crash the player.
        }
    }

    private func tick() {
        web?.evaluateJavaScript("""
        (()=>{
          \(Self.pickJS)
          // Auto-confirm "still watching / listening" dialogs so playback
          // never stalls waiting on a human click.
          try{
            var dlgs=document.querySelectorAll('yt-confirm-dialog-renderer,paper-dialog');
            for(var di=0;di<dlgs.length;di++){
              var dt=((dlgs[di].innerText||'').toLowerCase());
              if(dt.indexOf('continue watching')!==-1||dt.indexOf('still watching')!==-1||dt.indexOf('still listening')!==-1){
                var btns=dlgs[di].querySelectorAll('button');
                for(var bi=0;bi<btns.length;bi++){
                  var bt=((btns[bi].innerText||'').trim().toLowerCase());
                  if(bt==='yes'||bt==='continue'||bt==='ok'){btns[bi].click();break;}
                }
              }
            }
          }catch(e){}
          const v=window.__nv();
          if(!v)return JSON.stringify({dead:true});
          // Hardened ad detection: player's own state, or a VISIBLE ad node.
          // (Hidden DOM leftovers must not count — that was muting real songs.)
          var adState=-1;
          try{var mp=document.querySelector('#movie_player');if(mp&&mp.getAdState)adState=mp.getAdState();}catch(e){}
          function vis(el){try{return !!(el&&(el.offsetWidth||el.offsetHeight||(el.getClientRects&&el.getClientRects().length)));}catch(e){return false;}}
          var skipBtn=document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad button');
          var ad=(adState===1)||!!(document.querySelector('#movie_player.ad-showing')&&vis(document.querySelector('#movie_player')))||vis(skipBtn);
          if(ad){
            v.muted=true;
            if(skipBtn&&vis(skipBtn)){try{skipBtn.click();}catch(e){}}
          }
          const t=(s)=>((s||'').trim());
          const bar=document.querySelector('ytmusic-player-bar');
          const title=t(bar?.querySelector('.title')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ')[0]);
          const artist=t(bar?.querySelector('.byline')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ').slice(1).join(' - '));
          return JSON.stringify({
            p:!!v.paused,t:v.currentTime||0,d:v.duration||0,title:title,artist:artist,ad:ad,as:adState,
            rs:v.readyState,ns:v.networkState,err:(v.error?v.error.code:-1),
            end:(v.ended?1:0),seek:(v.seeking?1:0),
            buf:(v.buffered&&v.buffered.length?v.buffered.end(v.buffered.length-1):0),
            dec:(window.webkitVideoDecodedByteCount||0),vol:v.volume,mu:(v.muted?1:0),
            src:(v.currentSrc||'').slice(0,60),
            vids:document.querySelectorAll('video').length,
            ps:(function(){try{return document.querySelector('#movie_player')&&document.querySelector('#movie_player').getPlayerState?document.querySelector('#movie_player').getPlayerState():-1}catch(e){return -1}})()
          });
        })()
        """) { [weak self] res, _ in
            guard let self,
                  let s = res as? String,
                  let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            // Dead page (no usable video element at all).
            if (j["dead"] as? Bool) ?? false {
                if self.webIsPlaying {
                    // Don't nuke user navigation: only auto-reload when the page
                    // that died is the same one that was playing. If the user
                    // navigated (home/search/new song loading), wait it out.
                    let cur = self.web?.url
                    let samePage = (cur != nil && cur == self.lastPlayURL) || self.lastPlayURL == nil
                    if samePage {
                        self.deadTicks += 1
                        if self.deadTicks >= 4 {
                            self.deadTicks = 0
                            self.alog("DEAD-RELOAD (no video element for 8s) url=\(cur?.absoluteString ?? "nil")")
                            self.web?.reload()
                        }
                    } else {
                        self.deadTicks = 0
                    }
                }
                return
            }
            self.deadTicks = 0
            let isAd = (j["ad"] as? Bool) ?? false
            let adState = (j["as"] as? Int) ?? -99
            self.inAd = isAd
            // Heartbeat: ~1 line / 30s of real state — used to verify playback.
            self.hbTicks += 1
            if self.hbTicks % 15 == 0 {
                self.alog("STATE playing=\((j["p"] as? Bool) ?? true ? "no" : "yes") t=\(String(format: "%.1f", (j["t"] as? Double) ?? -1)) buf=\(String(format: "%.1f", (j["buf"] as? Double) ?? -1)) rs=\(j["rs"] ?? -1) ns=\(j["ns"] ?? -1) err=\(j["err"] ?? -1) ps=\(j["ps"] ?? -1) dec=\(String(format: "%.1f", (j["dec"] as? Double) ?? -1)) ad=\(isAd) as=\(adState) title=\(self.lastWebTitle)")
            }
            if isAd {
                self.adStreak += 1
                // Stay muted through the ad; restore the user's mute state after.
                // MUST target __nv() (the audible element) — a bare querySelector
                // can hit a hidden element while the ad blares from the real one.
                if !self.adMutedByUs {
                    self.adMutedByUs = true
                    self.mutedStreak = 0
                    self.alog("AD-START as=\(adState) t=\(String(format: "%.1f", (j["t"] as? Double) ?? -1)) title=\(self.lastWebTitle)")
                    self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v)v.muted=true;})()", completionHandler: nil)
                } else {
                    self.mutedStreak += 1
                }
                // Seek past only from the 2nd consecutive ad tick: a single-tick
                // blip must never be able to skip a real song.
                if self.adStreak == 2 {
                    self.alog("AD-SEEK as=\(adState)")
                    self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v&&isFinite(v.duration)&&v.duration>0){try{v.currentTime=v.duration;}catch(e){}}const b=document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad button');if(b){try{b.click();}catch(e){}}})()", completionHandler: nil)
                } else {
                    self.web?.evaluateJavaScript("(()=>{const b=document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad button');if(b){try{b.click();}catch(e){}}})()", completionHandler: nil)
                }
                // Dead-man's switch: muted longer than ~45s straight is almost
                // certainly a false positive — unmute rather than silence songs.
                if self.mutedStreak >= 22 {
                    self.mutedStreak = 0
                    self.alog("AD-FORCE-UNMUTE after 45s (likely false positive)")
                    self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v)v.muted=\(self.lastVolume <= 0);})()", completionHandler: nil)
                }
                return
            }
            if self.adStreak > 0 {
                self.alog("AD-END after \(self.adStreak) ticks")
            }
            self.adStreak = 0
            self.mutedStreak = 0
            if self.adMutedByUs {
                self.adMutedByUs = false
                let m = self.lastVolume <= 0
                self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v)v.muted=\(m);})()", completionHandler: nil)
            }
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
                    self.pausedStreak = 0
                    if !title.isEmpty { self.lastPlayURL = self.web?.url }
                    if self.resumeAfterLoad {
                        // Page reloaded after a death: press play (autoplay allowed).
                        self.resumeAfterLoad = false
                        self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v&&v.paused){v.play();}})()", completionHandler: nil)
                    }
                    if t != self.lastAdvanceT {
                        self.lastAdvanceT = t
                        self.frozenTicks = 0
                    } else {
                        // Clock frozen while "playing" = stalled buffer. v.play()
                        // on a truly-playing element is a harmless no-op, so call
                        // it unconditionally (the old v.paused guard never fired
                        // here because playing implies !paused). Second stage
                        // nudges the clock forward in case play() alone stalls.
                        self.frozenTicks += 1
                        if self.frozenTicks == 6 {
                            self.alog("STALL-RESUME at t=\(String(format: "%.1f", t))")
                            self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v){try{v.play();}catch(e){}}})()", completionHandler: nil)
                        } else if self.frozenTicks >= 12 {
                            self.frozenTicks = 0
                            self.alog("STALL-SEEK at t=\(String(format: "%.1f", t))")
                            self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v){try{if(isFinite(v.duration)&&v.duration>0)v.currentTime=Math.min(v.duration,Math.max(0,(v.currentTime||0)+1));v.play();}catch(e){}}})()", completionHandler: nil)
                        }
                    }
                    if !title.isEmpty, title != self.lastWebTitle {
                        self.lastWebTitle = title
                        PlayHistoryStore.shared.record(title: title, source: "YouTube Web")
                    }
                    RemoteCommands.refresh()
                } else if m.source == "YouTube Web" {
                    if m.isPlaying { m.isPlaying = false }
                    self.frozenTicks = 0
                    // Unexpected stall (not a user pause — those clear the flag):
                    // give it ~6s to recover on its own, then press play.
                    if m.expectingWebPlay {
                        self.pausedStreak += 1
                        if self.pausedStreak >= 3 {
                            self.pausedStreak = 0
                            self.alog("STALL-RESUME (paused 6s while expected)")
                            self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v&&v.paused){v.play();}})()", completionHandler: nil)
                        }
                    } else {
                        self.pausedStreak = 0
                    }
                    RemoteCommands.refresh()
                }
            }
        }
    }

    // MARK: - Network-level ad blocking

    /// Safari-style content rules, generated from upstream EasyList + EasyPrivacy
    /// with Adblock Plus's official abp2blocklist converter (same tooling as ABP
    /// for iOS — see Scripts/refresh-adblock.sh). Scoped to ad delivery +
    /// analytics; playback, thumbnails and UI domains are untouched.
    /// Falls back to a small hand-written list if the bundle file is missing.
    static func adBlockRulesJSON() -> String {
        if let url = Bundle.main.url(forResource: "adblock-youtube", withExtension: "json"),
           let s = try? String(contentsOf: url, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        return handRulesJSON
    }

    static let handRulesJSON = """
    [
     {"trigger":{"url-filter":".*\\.doubleclick\\.net.*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":".*\\.googlesyndication\\.com.*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":".*\\.googleadservices\\.com.*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":".*youtube\\.com/api/stats/ads.*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":".*youtube\\.com/pagead/.*"},"action":{"type":"block"}}
    ]
    """

    static func applyAdBlock(to controller: WKUserContentController, done: @escaping () -> Void) {
        let rules = adBlockRulesJSON()
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "com.local.notchapp.adblock",
            encodedContentRuleList: rules
        ) { list, _ in
            if let list = list {
                controller.add(list)
            }
            done()
        }
    }
}

// MARK: - Web process recovery

extension YTWebPlayer: WKNavigationDelegate {
    /// If the web content process dies mid-song, reload the last playing page
    /// and resume. Without this the tab goes permanently white/silent.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastAdvanceT = -1
        frozenTicks = 0
        deadTicks = 0
        guard webIsPlaying || MusicService.shared.source == "YouTube Web" else { return }
        resumeAfterLoad = true
        if let u = lastPlayURL {
            webView.load(URLRequest(url: u))
        } else {
            webView.reload()
        }
    }
}
