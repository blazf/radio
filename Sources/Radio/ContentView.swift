import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: RadioPlayer

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Station.all) { station in
                    StationButton(station: station)
                }
            }

            Divider()

            HStack(spacing: 12) {
                statusView
                Spacer()
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 110)
            }
            .frame(height: 28)
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var statusView: some View {
        switch player.status {
        case .stopped:
            Label("Not playing", systemImage: "stop.fill")
                .foregroundStyle(.secondary)
        case .buffering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(player.current?.name ?? "")…")
            }
            .foregroundStyle(.secondary)
        case .playing:
            VStack(alignment: .leading, spacing: 2) {
                Label(player.current?.name ?? "", systemImage: "dot.radiowaves.left.and.right")
                    .fontWeight(.medium)
                if let now = player.nowPlaying {
                    Text(now)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

private struct StationButton: View {
    @EnvironmentObject private var player: RadioPlayer
    let station: Station

    private var isActive: Bool {
        player.current == station && player.status != .stopped
    }

    var body: some View {
        Button {
            player.toggle(station)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    StationIcon(station: station)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                    Image(systemName: isActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isActive ? Color.accentColor : Color.secondary)
                        .background(Circle().fill(.white).padding(2))
                        .offset(x: 6, y: 6)
                }
                Text(station.name)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isActive ? "Stop \(station.name)" : "Play \(station.name)")
    }
}

private struct StationIcon: View {
    let station: Station

    var body: some View {
        if let url = station.iconURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "radio").font(.title2).foregroundStyle(.secondary))
        }
    }
}
