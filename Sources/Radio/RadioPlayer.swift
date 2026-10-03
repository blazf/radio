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

    /// Where audio goes: this Mac, or a Sonos group on the local network.
    enum Output: Hashable {
        case local
        case sonos(SonosGroup)

        var name: String {
            switch self {
            case .local: return "This Mac"
            case .sonos(let group): return group.name
            }
        }

        var systemImage: String {
            switch self {
            case .local: return "laptopcomputer"
            case .sonos(let group): return group.memberIDs.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill"
            }
        }
    }

    @Published private(set) var current: Station?
    @Published private(set) var status: Status = .stopped { didSet { syncRemote() } }
    @Published private(set) var nowPlaying: String? { didSet { syncRemote() } }
    @Published private(set) var output: Output = .local
    @Published private(set) var sonosGroups: [SonosGroup] = []
    @Published var volume: Float = 0.8 {
        didSet { applyVolume() }
    }

    /// True while a station is playing or connecting.
    var isActive: Bool {
        switch status {
        case .playing, .buffering: return true
        case .stopped, .failed: return false
        }
    }

    /// Choices for the output picker; keeps the selected group listed even if
    /// it has dropped out of discovery.
    var availableOutputs: [Output] {
        var outputs: [Output] = [.local] + sonosGroups.map { .sonos($0) }
        if !outputs.contains(output) { outputs.append(output) }
        return outputs
    }

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var observers: [NSKeyValueObservation] = []
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataDelegate: MetadataDelegate?
    private var remote: RemoteCommands?

    private static let outputKey = "sonosOutputGroup"
    private let discovery = SonosDiscovery()
    private var pendingRestoreID: String?
    private var sonosTask: Task<Void, Never>?
    private var sonosQueue: Task<Void, Error>?
    private var volumeTask: Task<Void, Never>?
    private var localVolume: Float = 0.8
    private var syncingVolume = false

    init() {
        remote = RemoteCommands { [weak self] in self?.stop() }
        pendingRestoreID = UserDefaults.standard.string(forKey: Self.outputKey)
        discovery.onChange = { [weak self] groups in self?.groupsChanged(groups) }
        discovery.start()
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
        teardown()
        current = station
        status = .buffering
        nowPlaying = nil

        switch output {
        case .local: playLocally(station)
        case .sonos(let group): playOnSonos(station, group: group)
        }
    }

    func stop() {
        let wasActive = isActive
        teardown()
        if wasActive, case .sonos(let group) = output {
            sonos { try await SonosClient.stop(group) }
        }
    }

    /// Switches where audio goes, moving the current station along with it.
    func setOutput(_ new: Output) {
        pendingRestoreID = nil
        guard new != output else { return }
        let station = isActive ? current : nil
        stop()
        output = new

        switch new {
        case .local:
            UserDefaults.standard.removeObject(forKey: Self.outputKey)
            setVolumeQuietly(localVolume)
        case .sonos(let group):
            UserDefaults.standard.set(group.id, forKey: Self.outputKey)
            Task {
                guard let level = try? await SonosClient.groupVolume(group), output == new else { return }
                setVolumeQuietly(Float(level) / 100)
            }
        }

        if let station { play(station) }
    }

    private func groupsChanged(_ groups: [SonosGroup]) {
        sonosGroups = groups
        if case .sonos(let selected) = output {
            // Pick up renames, or follow the speaker into whatever group it joined.
            if let fresh = groups.first(where: { $0.id == selected.id })
                ?? groups.first(where: { $0.memberIDs.contains(selected.id) }) {
                output = .sonos(fresh)
            }
        } else if let id = pendingRestoreID, let group = groups.first(where: { $0.id == id }) {
            if !isActive { setOutput(.sonos(group)) }
            pendingRestoreID = nil
        }
    }

    private func applyVolume() {
        guard !syncingVolume else { return }
        switch output {
        case .local:
            localVolume = volume
            player?.volume = volume
        case .sonos(let group):
            // Debounce slider drags into a single request.
            volumeTask?.cancel()
            let level = Int((volume * 100).rounded())
            volumeTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                try? await SonosClient.setGroupVolume(group, level)
            }
        }
    }

    private func setVolumeQuietly(_ value: Float) {
        syncingVolume = true
        volume = value
        syncingVolume = false
    }

    /// Runs Sonos commands one after another so a quick stop/play can't arrive out of order.
    @discardableResult
    private func sonos(_ operation: @escaping () async throws -> Void) -> Task<Void, Error> {
        let previous = sonosQueue
        let task = Task {
            _ = await previous?.result
            try await operation()
        }
        sonosQueue = task
        return task
    }

    private func playOnSonos(_ station: Station, group: SonosGroup) {
        let uri = station.sonosURI
        let command = sonos { try await SonosClient.play(group, uri: uri, title: station.name) }

        sonosTask = Task { [weak self] in
            do {
                try await command.value
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed(error.localizedDescription)
                return
            }

            // Follow the speaker's state; it can also be stopped or switched from the Sonos app.
            var started = false
            var failures = 0
            let deadline = Date().addingTimeInterval(15)
            while !Task.isCancelled {
                do {
                    let snapshot = try await SonosClient.snapshot(group)
                    guard !Task.isCancelled, let self else { return }
                    failures = 0
                    if snapshot.uri != uri {
                        self.teardown()
                        return
                    }
                    switch snapshot.state {
                    case "PLAYING":
                        started = true
                        self.status = .playing
                    case "TRANSITIONING":
                        self.status = .buffering
                    default:
                        if started {
                            self.teardown()
                            return
                        }
                        if Date() > deadline {
                            self.teardown()
                            self.status = .failed("\(group.name) couldn't play the stream")
                            return
                        }
                    }
                    self.nowPlaying = snapshot.title
                } catch {
                    guard !Task.isCancelled else { return }
                    failures += 1
                    if failures >= 3 {
                        self?.teardown()
                        self?.status = .failed("Lost connection to \(group.name)")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func playLocally(_ station: Station) {
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

    /// Drops all playback state without telling a Sonos speaker to stop.
    private func teardown() {
        sonosTask?.cancel()
        sonosTask = nil
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
