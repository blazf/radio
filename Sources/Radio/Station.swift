import Foundation

struct Station: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    /// Logo file in the app's Resources folder, named "<id>.png".
    var iconURL: URL? {
        Bundle.main.url(forResource: id, withExtension: "png")
    }

    static let all: [Station] = [
        Station(id: "val202", name: "Val 202",     url: URL(string: "https://mp3.rtvslo.si/val202")!),
        Station(id: "prvi",   name: "Radio Prvi",  url: URL(string: "https://mp3.rtvslo.si/ra1")!),
        Station(id: "ars",    name: "Radio Ars",   url: URL(string: "https://mp3.rtvslo.si/ars")!),
        Station(id: "sora",   name: "Radio Sora",  url: URL(string: "http://radio-sora.si:8000/radio-sora.mp3")!),
        Station(id: "rock",   name: "Rock Radio",  url: URL(string: "https://stream.nextmedia.si/proxy/rockr2_2?mp=/rock")!),
        Station(id: "rsi",    name: "Radio Si",    url: URL(string: "https://mp3.rtvslo.si/rsi")!),
    ]
}
