import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var player: RadioPlayer
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch player.status {
            case .stopped:
                Text("Not playing")
            case .buffering:
                Text("Connecting to \(player.current?.name ?? "")…")
            case .playing:
                Text("Playing \(player.current?.name ?? "")")
                if let song = player.nowPlaying {
                    Text(song)
                }
            case .failed(let message):
                Text("Error: \(message)")
            }
        }

        Divider()

        ForEach(Station.all) { station in
            Toggle(isOn: Binding(
                get: { player.current == station && player.isActive },
                set: { _ in player.toggle(station) }
            )) {
                if let image = StationImages.menuImage(for: station) {
                    Label { Text(station.name) } icon: { image }
                } else {
                    Text(station.name)
                }
            }
        }

        Divider()

        Button("Show Radio Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Toggle("Start at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))

        Divider()

        Button("Quit Radio") {
            NSApp.terminate(nil)
        }
    }
}

/// Small cached logos for menu rows.
enum StationImages {
    private static var cache: [String: Image] = [:]

    static func menuImage(for station: Station) -> Image? {
        if let cached = cache[station.id] { return cached }
        guard let url = station.iconURL, let nsImage = NSImage(contentsOf: url) else { return nil }
        nsImage.size = NSSize(width: 18, height: 18)
        let image = Image(nsImage: nsImage)
        cache[station.id] = image
        return image
    }
}
