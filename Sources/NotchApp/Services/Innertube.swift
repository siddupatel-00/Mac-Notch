import Foundation

/// First-party YouTube search (fast HTTPS POST, ~1s — verified working).
/// Playback still goes through yt-dlp-resolved streams; search never waited on it.
struct InnertubeTrack {
    let id: String
    let title: String
    let artist: String
    let durationSecs: Double
    let atv: Bool
    let thumb: String
}

enum Innertube {
    static let key = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    static func search(_ query: String) async throws -> [InnertubeTrack] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/search?key=\(key)&prettyPrint=false")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20240101.00.00", "hl": "en", "gl": "US"]],
            "query": query
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    static func parse(_ data: Data) -> [InnertubeTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabs = ((json["contents"] as? [String: Any])?["tabbedSearchResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] else { return [] }
        var out: [InnertubeTrack] = []
        for t in tabs {
            guard let sections = ((t["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any],
                  let list = sections["contents"] as? [[String: Any]] else { continue }
            for s in list {
                guard let items = (s["itemSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] else { continue }
                for it in items {
                    guard let r = it["musicResponsiveListItemRenderer"] as? [String: Any],
                          let playBtn = (((r["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any],
                          let endpoint = playBtn["playNavigationEndpoint"] as? [String: Any],
                          let watch = endpoint["watchEndpoint"] as? [String: Any],
                          let vid = watch["videoId"] as? String,
                          !vid.isEmpty else { continue }
                    let atv = (((watch["watchEndpointMusicSupportedConfigs"] as? [String: Any])?["watchEndpointMusicConfig"] as? [String: Any])?["musicVideoType"] as? String) == "MUSIC_VIDEO_TYPE_ATV"
                    let cols = (r["flexColumns"] as? [[String: Any]]) ?? []
                    func runs(_ i: Int) -> String {
                        guard cols.count > i,
                              let rs = ((cols[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] else { return "" }
                        return rs.compactMap { $0["text"] as? String }.joined()
                    }
                    let title = runs(0)
                    guard !title.isEmpty else { continue }
                    let parts = runs(1).components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && $0 != "Song" && $0 != "Video" }
                    var dur: Double = 0
                    if let fixed = r["fixedColumns"] as? [[String: Any]] {
                        for f in fixed {
                            if let fr = ((f["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] {
                                let s = fr.compactMap { $0["text"] as? String }.joined()
                                let pcs = s.components(separatedBy: ":").compactMap(Double.init)
                                if pcs.count == 2 { dur = pcs[0] * 60 + pcs[1]; break }
                                if pcs.count == 3 { dur = pcs[0] * 3600 + pcs[1] * 60 + pcs[2]; break }
                            }
                        }
                    }
                    out.append(InnertubeTrack(id: vid, title: title, artist: parts.first ?? "", durationSecs: dur, atv: atv, thumb: Self.thumbURL(r)))
                    if out.count >= 30 { return out }
                }
            }
        }
        return out
    }

    /// Smallest thumbnail >= 120px wide (music list art is tiny in our rows).
    static func thumbURL(_ r: [String: Any]) -> String {
        guard let thumbs = (((r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
              !thumbs.isEmpty else { return "" }
        let sorted = thumbs.sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        return (sorted.first(where: { ($0["width"] as? Int ?? 0) >= 120 }) ?? sorted.last)?["url"] as? String ?? ""
    }
}
