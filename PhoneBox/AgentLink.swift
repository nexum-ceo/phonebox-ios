import Foundation
import CryptoKit
import Network
import Security

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// TLS delegate that trusts exactly one certificate: the SHA-256 fingerprint of the agent's self-signed certificate
/// (the "pin"). The pin comes from the pairing QR code. Redirects are never followed.
final class PinDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    let pin: String
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    init(pin: String) { self.pin = pin.lowercased() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = sha256Hex(SecCertificateCopyData(leaf) as Data)
        if fingerprint == pin { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) } // identity is the pinned certificate, nothing else
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { onOpen?() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { onClose?() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if task is URLSessionWebSocketTask { onClose?() } }
}

/// Connection to the PhoneBox agent on the computer (the iOS counterpart of AgentLink.kt).
///
/// The Android app has two routes: USB (adb reverse) and Wi-Fi / Tailscale. iOS has no adb, so this is the Wi-Fi route
/// only: https://<pc-address>:<port>, with the agent's self-signed certificate pinned and a per-computer token on every
/// request. The pairing data (addresses, token, certificate fingerprint) comes from the QR code on the computer's
/// settings page ("Pair a phone over Wi-Fi").
final class AgentLink: @unchecked Sendable {

    struct Reply { let code: Int; let contentType: String?; let body: Data }

    enum Route: String { case wifi, none }

    /// A computer this phone is paired with; the certificate fingerprint is its id.
    struct Pc: Codable, Equatable {
        let id: String
        let name: String
        let hosts: [String]
        let port: Int
        let token: String
        var macs: [String] = []
    }

    private let lock = NSLock()
    private var _route: Route = .none
    private var _pcs: [Pc]
    private var _activeId: String?
    private var preferredHost = 0
    private var sessions: [String: (URLSession, PinDelegate)] = [:]
    private var closed = false

    var route: Route { lock.lock(); defer { lock.unlock() }; return _route }
    private func setRoute(_ r: Route) { lock.lock(); _route = r; lock.unlock() }

    init() {
        if let json = Keychain.get("pcs"), let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([Pc].self, from: data) { _pcs = list } else { _pcs = [] }
        _activeId = Keychain.get("active")
        trackpad = TrackpadSocket(link: self)
    }

    private(set) var trackpad: TrackpadSocket!

    // MARK: paired computers

    private func save(_ list: [Pc], active: String?) {
        // callers hold the lock
        _pcs = list
        _activeId = active
        if let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) { Keychain.set("pcs", text) }
        Keychain.set("active", active ?? "")
    }

    func activePc() -> Pc? {
        lock.lock(); defer { lock.unlock() }
        return _pcs.first { $0.id == _activeId } ?? _pcs.first
    }

    var hasPairing: Bool { lock.lock(); defer { lock.unlock() }; return !_pcs.isEmpty }

    /// The paired computers for the panel: [{"id", "name", "active"}].
    func pcsJson() -> String {
        let active = activePc()?.id
        lock.lock(); let list = _pcs; lock.unlock()
        return jsonString(list.map { ["id": $0.id, "name": $0.name, "active": $0.id == active] as [String: Any] })
    }

    /// Makes another paired computer the one in use.
    @discardableResult
    func select(_ id: String) -> Bool {
        lock.lock()
        guard _pcs.contains(where: { $0.id == id }) else { lock.unlock(); return false }
        save(_pcs, active: id)
        preferredHost = 0
        lock.unlock()
        trackpad.close()
        return true
    }

    func forget(_ id: String) {
        lock.lock()
        let rest = _pcs.filter { $0.id != id }
        save(rest, active: _activeId == id ? rest.first?.id : _activeId)
        lock.unlock()
        trackpad.close()
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        trackpad.close()
    }


    // MARK: small synchronous helpers (locking is kept out of the async functions)

    private func noteConnected(host: Int, route: Route?) {
        lock.lock(); defer { lock.unlock() }
        preferredHost = host
        if let route { _route = route }
    }

    private func storeMacs(_ macs: [String], for id: String) {
        lock.lock(); defer { lock.unlock() }
        if !closed, let index = _pcs.firstIndex(where: { $0.id == id }), _pcs[index].macs != macs {
            var list = _pcs
            list[index].macs = macs
            save(list, active: _activeId)
        }
    }

    private func nextPendingTrackpadEvent() -> TrackpadEvent? {
        httpTrackpadLock.lock(); defer { httpTrackpadLock.unlock() }
        if pendingEvents.isEmpty { inFlight = false; return nil }
        return pendingEvents.removeFirst()
    }

    private func storePaired(link: PairLink, hosts: [String], port: Int, token: String, macs reported: [String]?) {
        lock.lock(); defer { lock.unlock() }
        let id = link.fingerprint.lowercased()
        // an empty report (an adapter briefly not eligible) must not wipe the MACs already stored for it
        let pc = Pc(id: id, name: link.pc, hosts: hosts, port: port, token: token, macs: reported ?? _pcs.first { $0.id == id }?.macs ?? [])
        save(_pcs.filter { $0.id != id } + [pc], active: id)
        preferredHost = 0
    }

    // MARK: sessions

    func session(pin: String) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[pin.lowercased()] { return existing.0 }
        let delegate = PinDelegate(pin: pin)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:] // the computer is on the local network or Tailscale, never behind a proxy
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sessions[pin.lowercased()] = (s, delegate)
        return s
    }

    /// A session of its own (a WebSocket needs its delegate callbacks).
    func makeSession(pin: String, delegate: PinDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: requests

    /// Opens a long-lived GET (the live stream); nil when the computer is unreachable.
    func stream(_ path: String) async -> (Route, URLSession.AsyncBytes, HTTPURLResponse)? {
        guard let pc = activePc(), !pc.hosts.isEmpty else { return nil }
        let session = self.session(pin: pc.id)
        for i in orderedHosts(pc) {
            guard let url = URL(string: "https://\(pc.hosts[i]):\(pc.port)\(path)") else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            decorate(&request, token: pc.token, method: "GET")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                noteConnected(host: i, route: .wifi)
                return (.wifi, bytes, http)
            } catch { continue }
        }
        return nil
    }

    /// Forwards a request (method + path with query) to the agent.
    func request(method: String, pathAndQuery: String, body: Data? = nil, contentType: String? = nil) async -> Reply {
        if let reply = await wifi(method: method, pathAndQuery: pathAndQuery, timeout: 4, body: body, contentType: contentType, target: nil) {
            setRoute(.wifi)
            maybeRefreshMacs()
            return reply
        }
        setRoute(.none)
        return Reply(code: 503, contentType: "application/json", body: Data(#"{"error":"offline"}"#.utf8))
    }

    private func orderedHosts(_ pc: Pc) -> [Int] {
        lock.lock(); let preferred = preferredHost; lock.unlock()
        return pc.hosts.indices.sorted { a, b in
            let ka = a == preferred ? -1 : a, kb = b == preferred ? -1 : b
            return ka < kb
        }
    }

    private func decorate(_ request: inout URLRequest, token: String, method: String) {
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(DeviceInfo.appVersion, forHTTPHeaderField: "X-PhoneBox-App") // lets the agent offer updates
        request.setValue(DeviceInfo.deviceId, forHTTPHeaderField: "X-PhoneBox-Device")
        request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-PhoneBox-Model")
    }

    /// Over Wi-Fi to the active computer, or to [target] when a caller must reach one particular computer.
    private func wifi(method: String, pathAndQuery: String, timeout: TimeInterval, body: Data?, contentType: String?, target: Pc?) async -> Reply? {
        guard let pc = target ?? activePc(), !pc.hosts.isEmpty else { return nil }
        let session = self.session(pin: pc.id)
        // every POST acts on the computer (a container restart, a Home Assistant switch, a macro): none may run twice
        let controlPost = method == "POST"
        for i in (target == nil ? orderedHosts(pc) : Array(pc.hosts.indices)) {
            let host = pc.hosts[i]
            // A POST must not be sent to an address that may not answer: if it timed out we could not tell whether the
            // command ran. A quick connection test tells a dead address from a slow command.
            if controlPost, !(await Self.reachable(host: host, port: pc.port, timeout: 1.5)) { continue }
            guard let url = URL(string: "https://\(host):\(pc.port)\(pathAndQuery)") else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: controlPost ? 30 : timeout)
            decorate(&request, token: pc.token, method: method)
            if method == "POST" {
                request.httpBody = body ?? Data()
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if target == nil { noteConnected(host: i, route: nil) }
                let code = http.statusCode
                if !(100...599).contains(code) || (300...399).contains(code) {
                    return Reply(code: 502, contentType: "application/json", body: Data(#"{"error":"unexpected response"}"#.utf8))
                }
                return Reply(code: code, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
            } catch {
                if controlPost {
                    // The command may already have been submitted: do not try another address.
                    return Reply(code: 504, contentType: "application/json",
                                 body: Data(#"{"ok":false,"error":"The command result is unknown; check the computer before retrying"}"#.utf8))
                }
                continue // try the next address
            }
        }
        return nil
    }

    /// A TCP connection test (not a request): true when [host]:[port] accepts a connection within [timeout].
    static func reachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = NSLock()
            var finished = false
            func finish(_ ok: Bool) {
                once.lock()
                if finished { once.unlock(); return }
                finished = true
                once.unlock()
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: Wake-on-LAN data

    private let macRefreshLock = NSLock()
    private var macRefreshAt: [String: Date] = [:]

    /// Asks the agent for its MACs at most every 10 minutes per computer, so a replaced network card does not leave the
    /// Wake button sending to the old address.
    private func maybeRefreshMacs() {
        guard let pc = activePc() else { return }
        macRefreshLock.lock()
        if let last = macRefreshAt[pc.id], Date().timeIntervalSince(last) < 600 { macRefreshLock.unlock(); return }
        macRefreshAt[pc.id] = Date()
        macRefreshLock.unlock()
        Task.detached { [self] in
            guard let r = await wifi(method: "GET", pathAndQuery: "/api/wake/macs", timeout: 4, body: nil, contentType: nil, target: pc),
                  r.code == 200,
                  let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let macs = WakePacket.macs(from: json["macs"] as? [Any]) else { return }
            storeMacs(macs, for: pc.id)
        }
    }

    func canWake() -> Bool {
        guard let pc = activePc() else { return false }
        return !pc.macs.isEmpty && !WakePacket.linksOnOwnNetwork(hosts: pc.hosts, links: WakePacket.lanLinks()).isEmpty
    }

    /// Sends the magic packet for the stored computer [id]. The page only ever passes an id, never a MAC address.
    func wake(_ id: String) -> Bool {
        lock.lock(); let pc = _pcs.first { $0.id == id }; lock.unlock()
        guard let pc else { return false }
        let macs = pc.macs.compactMap { WakePacket.parseMac($0) }
        let links = WakePacket.linksOnOwnNetwork(hosts: pc.hosts, links: WakePacket.lanLinks())
        if macs.isEmpty || links.isEmpty { return false }
        DispatchQueue.global().async { _ = WakePacket.burst(macs: macs, links: links, hosts: pc.hosts) }
        return true
    }

    // MARK: trackpad over HTTP (when the WebSocket is not up yet)

    private struct TrackpadEvent { let type: String; var dx: Float; var dy: Float; var delta: Float }
    private let httpTrackpadLock = NSLock()
    private var inFlight = false
    private var pendingEvents: [TrackpadEvent] = []

    func sendTrackpad(type: String, dx: Float, dy: Float, delta: Float) {
        if !trackpad.send(type: type, dx: dx, dy: dy, delta: delta) {
            coalesceHttpTrackpad(TrackpadEvent(type: type, dx: dx, dy: dy, delta: delta))
        }
    }

    private func coalesceHttpTrackpad(_ event: TrackpadEvent) {
        httpTrackpadLock.lock()
        if inFlight {
            if var last = pendingEvents.last, last.type == event.type, event.type == "move" || event.type == "scroll" {
                last.dx += event.dx; last.dy += event.dy; last.delta += event.delta
                pendingEvents[pendingEvents.count - 1] = last
            } else { pendingEvents.append(event) }
            httpTrackpadLock.unlock()
            return
        }
        inFlight = true
        httpTrackpadLock.unlock()
        dispatchHttpTrackpad(event)
    }

    private func dispatchHttpTrackpad(_ event: TrackpadEvent) {
        Task.detached { [self] in
            let json = #"{"type":"\#(event.type)","dx":\#(event.dx),"dy":\#(event.dy),"delta":\#(event.delta)}"#
            _ = await request(method: "POST", pathAndQuery: "/api/trackpad", body: Data(json.utf8), contentType: "application/json")
            guard let next = nextPendingTrackpadEvent() else { return }
            dispatchHttpTrackpad(next)
        }
    }

    // MARK: pairing

    /// Why a pairing failed, so the shell can say it in the phone's language.
    enum PairFailure {
        case unreachable(pc: String, hosts: [String])
        case codeRejected(pc: String)
        case badAnswer(pc: String, code: Int)
        case wrongCertificate(pc: String)

        var message: String {
            switch self {
            case .unreachable(let pc, let hosts): return L("pair_failed_unreachable", pc, hosts.joined(separator: ", "))
            case .codeRejected(let pc): return L("pair_failed_code", pc)
            case .badAnswer(let pc, let code): return L("pair_failed_answer", pc, code)
            case .wrongCertificate: return L("pair_failed_certificate")
            }
        }
    }

    /// Pairing without USB: the computer's settings page shows a QR code with this link, and the phone trades the one-time
    /// code for the Wi-Fi key. The certificate fingerprint in the link is pinned from the first connection, so the key
    /// only ever goes to that computer.
    struct PairLink {
        let pc: String
        let fingerprint: String
        let port: Int
        let hosts: [String]
        let code: String

        /// The start of the certificate fingerprint, shown on the computer next to the QR code and in the confirmation.
        var check: String {
            let head = String(fingerprint.prefix(8)).uppercased()
            return stride(from: 0, to: head.count, by: 4).map { i -> String in
                let s = head.index(head.startIndex, offsetBy: i)
                return String(head[s..<head.index(s, offsetBy: min(4, head.count - i))])
            }.joined(separator: " ")
        }

        /// Only the addresses the agent offers: private network (10/8, 172.16/12, 192.168/16) and Tailscale (100.64/10) IPv4.
        static func isLocalAddress(_ host: String) -> Bool {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return false }
            var b: [Int] = []
            for p in parts {
                guard (1...3).contains(p.count), let n = Int(p), (0...255).contains(n) else { return false }
                b.append(n)
            }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
        }

        /// Reads https://ersinkoc.github.io/phonebox/pair/#v=1&... (the QR code) or phonebox://pair?v=1&... (the
        /// "Open in PhoneBox" button on that page). Anything malformed returns nil.
        static func parse(_ url: URL?) -> PairLink? {
            guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let raw: String?
            if comps.scheme == "https", comps.host == "ersinkoc.github.io", comps.path.hasPrefix("/phonebox/pair") { raw = comps.percentEncodedFragment }
            else if comps.scheme == "phonebox", comps.host == "pair" { raw = comps.percentEncodedQuery }
            else { raw = nil }
            guard let raw else { return nil }
            var q: [String: String] = [:]
            for part in raw.split(separator: "&") {
                guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
                q[String(part[part.startIndex..<i])] = String(part[part.index(after: i)...]).removingPercentEncoding ?? ""
            }
            guard q["v"] == "1" else { return nil }
            guard let fp = q["fp"]?.lowercased(), fp.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            guard let port = q["port"].flatMap({ Int($0) }), (1...65535).contains(port) else { return nil }
            guard let code = q["c"], code.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression) != nil else { return nil }
            let hosts = Array((q["h"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { isLocalAddress($0) }.prefix(8))
            if hosts.isEmpty { return nil }
            var name = String((q["pc"] ?? "").unicodeScalars.filter { $0.value >= 32 }.map(Character.init)).prefix(64).description
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "your computer" }
            return PairLink(pc: name, fingerprint: fp, port: port, hosts: hosts, code: code)
        }
    }

    /// Trades the link's one-time code for the Wi-Fi key and makes that computer the active one.
    /// Returns nil when paired, otherwise why it failed.
    func claim(_ link: PairLink) async -> PairFailure? {
        let session = self.session(pin: link.fingerprint)
        var problem: PairFailure = .unreachable(pc: link.pc, hosts: link.hosts)
        for host in link.hosts {
            guard let url = URL(string: "https://\(host):\(link.port)/api/pair/claim") else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-PhoneBox-Model")
            request.httpBody = jsonString(["code": link.code]).data(using: .utf8)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                switch http.statusCode {
                case 200: break
                case 403: return .codeRejected(pc: link.pc)
                default: problem = .badAnswer(pc: link.pc, code: http.statusCode); continue
                }
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if (j["fingerprint"] as? String)?.lowercased() != link.fingerprint { return .wrongCertificate(pc: link.pc) }
                guard let token = j["token"] as? String else { continue }
                let reported = (j["hosts"] as? [String])?.filter { PairLink.isLocalAddress($0) } ?? []
                let hosts = reported.isEmpty ? link.hosts : reported
                let reportedMacs = WakePacket.macs(from: j["macs"] as? [Any])
                storePaired(link: link, hosts: hosts, port: (j["port"] as? Int) ?? link.port, token: token, macs: reportedMacs)
                return nil
            } catch let error as URLError {
                switch error.code {
                case .cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                    problem = .wrongCertificate(pc: link.pc)
                default: break // try the next address
                }
            } catch { continue }
        }
        return problem
    }
}
