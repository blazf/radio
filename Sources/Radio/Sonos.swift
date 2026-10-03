import Foundation
import Network
import os

private let log = Logger(subsystem: "ai.extrakt.hobby.radio", category: "sonos")

/// A Sonos zone group (one room, a stereo pair, or several grouped rooms).
/// Commands go to the group coordinator; identity is the coordinator UUID.
struct SonosGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: URL
    let memberIDs: [String]

    static func == (a: SonosGroup, b: SonosGroup) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds Sonos players via Bonjour and reads the current zone group topology
/// from any one of them.
@MainActor
final class SonosDiscovery {
    var onChange: (([SonosGroup]) -> Void)?

    private var browser: NWBrowser?
    private var devices: [URL] = []
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            log.info("Bonjour browser state: \(String(describing: state), privacy: .public)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            log.info("Bonjour found \(results.count) Sonos services")
            let urls = results.compactMap { result -> URL? in
                guard case .bonjour(let txt) = result.metadata,
                      let location = txt["location"].flatMap(URL.init(string:)) else { return nil }
                return location.sonosBaseURL
            }
            Task { @MainActor in
                self?.devices = Array(Set(urls))
                self?.refresh()
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        // Groups change without Bonjour noticing, so re-read them now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        refreshTask?.cancel()
        let devices = self.devices
        refreshTask = Task {
            for device in devices {
                do {
                    let groups = try await SonosClient.zoneGroups(from: device)
                    guard !Task.isCancelled else { return }
                    log.info("Read \(groups.count) Sonos groups from \(device.absoluteString, privacy: .public)")
                    onChange?(groups)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    log.error("Topology from \(device.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Requests fail until the user allows local network access, so retry soon.
            guard !devices.isEmpty, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            refresh()
        }
    }
}

/// Minimal UPnP/SOAP client for the bits of the Sonos local API we need.
enum SonosClient {
    struct Snapshot {
        let state: String
        let uri: String
        let title: String?
    }

    enum Failure: LocalizedError {
        case upnp(action: String, code: String?)

        var errorDescription: String? {
            switch self {
            case .upnp(let action, let code):
                return "Sonos \(action) failed" + (code.map { " (error \($0))" } ?? "")
            }
        }
    }

    private static let avTransport = ("/MediaRenderer/AVTransport/Control", "urn:schemas-upnp-org:service:AVTransport:1")
    private static let groupRendering = ("/MediaRenderer/GroupRenderingControl/Control", "urn:schemas-upnp-org:service:GroupRenderingControl:1")
    private static let topology = ("/ZoneGroupTopology/Control", "urn:schemas-upnp-org:service:ZoneGroupTopology:1")

    static func play(_ group: SonosGroup, uri: String, title: String) async throws {
        let metadata = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="R:0/0/0" parentID="R:0/0" restricted="true"><dc:title>\(title.xmlEscaped)</dc:title>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc></item></DIDL-Lite>
        """
        _ = try await call(group.baseURL, avTransport, "SetAVTransportURI",
                           [("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
        _ = try await call(group.baseURL, avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    static func stop(_ group: SonosGroup) async throws {
        _ = try await call(group.baseURL, avTransport, "Stop", [("InstanceID", "0")])
    }

    static func snapshot(_ group: SonosGroup) async throws -> Snapshot {
        async let transport = call(group.baseURL, avTransport, "GetTransportInfo", [("InstanceID", "0")])
        async let media = call(group.baseURL, avTransport, "GetMediaInfo", [("InstanceID", "0")])
        async let position = call(group.baseURL, avTransport, "GetPositionInfo", [("InstanceID", "0")])

        let state = try await transport.element("CurrentTransportState") ?? ""
        let uri = try await media.element("CurrentURI") ?? ""
        let title = try await position.element("TrackMetaData")?
            .element("r:streamContent")
            .flatMap(cleanTitle)
        return Snapshot(state: state, uri: uri, title: title)
    }

    /// Stream titles are usually "Artist - Title", but some arrive as
    /// "TYPE=SNG|TITLE x|ARTIST y|ALBUM z" and "ZPSTR_*" are status placeholders.
    private static func cleanTitle(_ raw: String) -> String? {
        if raw.isEmpty || raw.hasPrefix("ZPSTR_") { return nil }
        guard raw.hasPrefix("TYPE=") else { return raw }
        var fields: [String: String] = [:]
        for part in raw.split(separator: "|") {
            let pair = part.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        let parts = [fields["ARTIST"], fields["TITLE"]].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    static func groupVolume(_ group: SonosGroup) async throws -> Int {
        // Snapshot first so later SetGroupVolume calls keep the rooms' relative levels.
        _ = try await call(group.baseURL, groupRendering, "SnapshotGroupVolume", [("InstanceID", "0")])
        let body = try await call(group.baseURL, groupRendering, "GetGroupVolume", [("InstanceID", "0")])
        return Int(body.element("CurrentVolume") ?? "") ?? 0
    }

    static func setGroupVolume(_ group: SonosGroup, _ volume: Int) async throws {
        _ = try await call(group.baseURL, groupRendering, "SetGroupVolume",
                           [("InstanceID", "0"), ("DesiredVolume", String(min(max(volume, 0), 100)))])
    }

    static func zoneGroups(from device: URL) async throws -> [SonosGroup] {
        let body = try await call(device, topology, "GetZoneGroupState", [])
        guard let state = body.element("ZoneGroupState") else { return [] }
        return TopologyParser.parse(state)
    }

    private static func call(_ base: URL, _ service: (path: String, type: String), _ action: String,
                             _ args: [(String, String)]) async throws -> String {
        let argXML = args.map { "<\($0.0)>\($0.1.xmlEscaped)</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.type)">\(argXML)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: base.appendingPathComponent(service.path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.upnp(action: action, code: body.element("errorCode"))
        }
        return body
    }
}

extension Station {
    /// Sonos plays plain internet radio via the x-rincon-mp3radio scheme
    /// (fetched over HTTP; every station here serves HTTP as well).
    var sonosURI: String {
        let s = url.absoluteString
        guard let range = s.range(of: "://") else { return s }
        return "x-rincon-mp3radio://" + s[range.upperBound...]
    }
}

private final class TopologyParser: NSObject, XMLParserDelegate {
    private struct Member { let id: String; let name: String; let base: URL?; let visible: Bool }

    private var groups: [SonosGroup] = []
    private var coordinator: String?
    private var members: [Member] = []

    static func parse(_ xml: String) -> [SonosGroup] {
        let delegate = TopologyParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "ZoneGroup":
            coordinator = attributes["Coordinator"]
            members = []
        case "ZoneGroupMember":
            members.append(Member(id: attributes["UUID"] ?? "",
                                  name: attributes["ZoneName"] ?? "",
                                  base: attributes["Location"].flatMap(URL.init(string:))?.sonosBaseURL,
                                  visible: attributes["Invisible"] != "1"))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "ZoneGroup", let coordinator,
              let lead = members.first(where: { $0.id == coordinator }), let base = lead.base else { return }
        // Stereo pairs and subs show up as invisible members of the same room.
        var names = [lead.name]
        for member in members where member.visible && !names.contains(member.name) {
            names.append(member.name)
        }
        groups.append(SonosGroup(id: coordinator, name: names.joined(separator: " + "),
                                 baseURL: base, memberIDs: members.map(\.id)))
    }
}

private extension URL {
    /// http://host:1400 from a device description URL.
    var sonosBaseURL: URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = port
        return parts.url
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    var xmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Unescaped text content of the first <tag>…</tag> in a SOAP body.
    func element(_ tag: String) -> String? {
        guard let open = range(of: "<\(tag)>"),
              let close = range(of: "</\(tag)>", range: open.upperBound..<endIndex) else { return nil }
        return String(self[open.upperBound..<close.lowerBound]).xmlUnescaped
    }
}
