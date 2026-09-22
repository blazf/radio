import AVFoundation
import Combine
import Foundation

@MainActor
final class RadioPlayer: ObservableObject {
    enum Status: Equatable {
        case stopped
        case buffering
        case playing
        case failed(String)
    }

    @Published private(set) var current: Station?
    @Published private(set) var status: Status = .stopped { didSet { syncRemote() } }
    @Published private(set) var nowPlaying: String? { didSet { syncRemote() } }
    @Published var volume: Float = 0.8 {
        didSet { player?.volume = volume }
    }

    /// True while a station is playing or connecting.
    var isActive: Bool {
        switch status {
        case .playing, .buffering: return true
        case .stopped, .failed: return false
        }
    }

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var observers: [NSKeyValueObservation] = []
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataDelegate: MetadataDelegate?
    private var remote: RemoteCommands?

    init() {
        remote = RemoteCommands { [weak self] in self?.stop() }
    }

    private func syncRemote() {
        remote?.update(station: current, nowPlaying: nowPlaying, playing: isActive)
    }

    func toggle(_ station: Station) {
        if current == station, status != .stopped {
            stop()
        } else {
            play(station)
        }
    }

    func play(_ station: Station) {
        stop()
        current = station
        status = .buffering
        nowPlaying = nil

        let item = AVPlayerItem(url: station.url)
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true

        let delegate = MetadataDelegate { [weak self] title in
            Task { @MainActor in self?.nowPlaying = title }
        }
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(delegate, queue: .main)
        item.add(output)
        metadataOutput = output
        metadataDelegate = delegate

        observers = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                Task { @MainActor in
                    guard let self, self.player === p else { return }
                    switch p.timeControlStatus {
                    case .playing: self.status = .playing
                    case .waitingToPlayAtSpecifiedRate: self.status = .buffering
                    case .paused:
                        if case .failed = self.status { } else if self.current != nil { self.status = .stopped }
                    @unknown default: break
                    }
                }
            },
            item.observe(\.status, options: [.new]) { [weak self] i, _ in
                Task { @MainActor in
                    guard let self, self.item === i else { return }
                    if i.status == .failed {
                        self.status = .failed(i.error?.localizedDescription ?? "Stream failed")
                    }
                }
            },
        ]

        self.item = item
        self.player = player
        player.play()
    }

    func stop() {
        observers.removeAll()
        player?.pause()
        player = nil
        item = nil
        metadataOutput = nil
        metadataDelegate = nil
        status = .stopped
        nowPlaying = nil
    }
}

private final class MetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onTitle: (String?) -> Void

    init(onTitle: @escaping (String?) -> Void) {
        self.onTitle = onTitle
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let item = groups
            .flatMap(\.items)
            .first { $0.identifier == .icyMetadataStreamTitle || $0.commonKey == .commonKeyTitle }
        let onTitle = self.onTitle
        Task {
            let title = try? await item?.load(.value) as? String
            onTitle(title?.isEmpty == false ? title : nil)
        }
    }
}
