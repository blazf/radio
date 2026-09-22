import AppKit
import Foundation
import MediaPlayer

/// Routes system media controls (keyboard play/pause keys, AirPods taps,
/// Control Center) to the player. Pause, stop and play/pause-toggle stop the
/// radio; play is deliberately swallowed so nothing resumes on its own.
@MainActor
final class RemoteCommands {
    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []

    init(onStop: @escaping @MainActor () -> Void) {
        let stop: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            Task { @MainActor in onStop() }
            return .success
        }
        // Report success without doing anything so the system does not hand
        // the key to another app (e.g. launch Music).
        let ignore: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in .success }

        for command in [center.pauseCommand, center.stopCommand, center.togglePlayPauseCommand] {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: stop)))
        }
        center.playCommand.isEnabled = true
        targets.append((center.playCommand, center.playCommand.addTarget(handler: ignore)))

        for command in [center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
    }

    deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }

    func update(station: Station?, nowPlaying: String?, playing: Bool) {
        guard let station else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying ?? station.name,
            MPMediaItemPropertyArtist: station.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let url = station.iconURL, let image = NSImage(contentsOf: url) {
            dict[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        info.nowPlayingInfo = dict
        // Stay registered as the now-playing app while paused so a later
        // "play" press reaches our no-op handler instead of another app.
        info.playbackState = playing ? .playing : .paused
    }
}
