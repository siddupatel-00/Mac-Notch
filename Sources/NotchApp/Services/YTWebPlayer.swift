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

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Response patching (the layer real YouTube adblockers use): neuter ad
        // scheduling inside youtubei player/next responses BEFORE the player
        // ever sees an ad. Runs at document start, main frame only.
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.adPatchScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Aggressive ad/tracker blocking at the network layer. Compiles async;
        // if the page beats it, we reload once so rules apply to everything.
        Self.applyAdBlock(to: cfg.userContentController) { [weak self] in
            guard let self, let w = self.web, w.url != nil else { return }
            w.reload()
        }
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
    private func tick() {
        web?.evaluateJavaScript("""
        (()=>{
          \(Self.pickJS)
          const v=window.__nv();
          if(!v)return 'none';
          // Authoritative first: the player's own ad state. Then DOM fallbacks.
          var adState=-1;
          try{var mp=document.querySelector('#movie_player');if(mp&&mp.getAdState)adState=mp.getAdState();}catch(e){}
          const ad=(adState===1)||!!document.querySelector('#movie_player.ad-showing,.ytp-ad-player-overlay,.ytp-ad-text,.ytp-ad-message,.ytp-ad-badge,.ytp-ad-skip-button,.ytp-ad-skip-button-modern');
          if(ad){
            v.muted=true;
            try{v.currentTime=Math.max(v.currentTime||0,(isFinite(v.duration)?v.duration:0));}catch(e){}
            const b=document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad button');
            if(b)b.click();
          }
          const t=(s)=>((s||'').trim());
          const bar=document.querySelector('ytmusic-player-bar');
          const title=t(bar?.querySelector('.title')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ')[0]);
          const artist=t(bar?.querySelector('.byline')?.textContent)
            || t(document.title.replace(/\\s*-\\s*YouTube Music\\s*$/,'').split(' - ').slice(1).join(' - '));
          return JSON.stringify({p:!!v.paused,t:v.currentTime||0,d:v.duration||0,title:title,artist:artist,ad:ad});
        })()
        """) { [weak self] res, _ in
            guard let self,
                  let s = res as? String, s != "none",
                  let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let isAd = (j["ad"] as? Bool) ?? false
            self.inAd = isAd
            if isAd {
                // Stay muted through the ad; restore the user's mute state after.
                // MUST target __nv() (the audible element) — a bare querySelector
                // can hit a hidden element while the ad blares from the real one.
                if !self.adMutedByUs {
                    self.adMutedByUs = true
                    self.web?.evaluateJavaScript("(()=>{\(Self.pickJS)const v=window.__nv();if(v)v.muted=true;})()", completionHandler: nil)
                }
                return
            }
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
