import Foundation
import MediaPlayer
import AppKit

/// Routes the Mac media keys (F7/F8/F9 + headphones) to the notch player
/// and publishes Now Playing so the system treats us as the audio app.
enum RemoteCommands {
    static func setup() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in control { $0.resume() } }
        c.pauseCommand.addTarget { _ in control { $0.pause() } }
        c.togglePlayPauseCommand.addTarget { _ in control { $0.toggle() } }
        c.nextTrackCommand.addTarget { _ in control { $0.next() } }
        c.previousTrackCommand.addTarget { _ in control { $0.previous() } }
    }

    private static func control(_ action: @escaping (MusicService) -> Void) -> MPRemoteCommandHandlerStatus {
        let m = MusicService.shared
        // Nothing loaded and nothing to resume: let the system pass the key to Music/Spotify.
        guard m.hasPlayable else { return .commandFailed }
        DispatchQueue.main.async { action(m) }
        return .success
    }

    /// Push current state to Now Playing (title, times, play/pause).
    /// Cheap — safe to call on every position tick.
    static func refresh() {
        let m = MusicService.shared
        guard m.hasPlayable else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: m.title,
            MPMediaItemPropertyArtist: m.subtitle,
            MPMediaItemPropertyPlaybackDuration: m.trackLength,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: m.position,
            MPNowPlayingInfoPropertyPlaybackRate: (m.isPlaying ? 1.0 : 0.0),
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
