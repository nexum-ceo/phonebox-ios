import CryptoKit
import Foundation

/// Chat with Claude Code on the paired computer (the counterpart of mac-starter/ChatRelay.swift). Messages travel through
/// the PhoneBox agent's push store over the phone's existing connection (TLS pinned, paired key):
/// a request goes to pbchat.req, PhoneBox Starter on the Mac runs Claude Code and writes pbchat.res, and announces
/// itself in pbchat.ready. Requests and replies carry an HMAC made with this phone's paired key, so neither side
/// trusts what another sender with the agent's webhook key may have written there.
@MainActor
final class ClaudeChat {
    private let link: AgentLink
    private let deliver: (String) -> Void
    private var timer: Timer?
    private var visible = false
    private var pending: String?        // the request Claude is answering
    private var lastReply = ""
    private var lastReady = ""
    private var tick = 0

    init(link: AgentLink, deliver: @escaping (String) -> Void) {
        self.link = link
        self.deliver = deliver
    }

    private var sessionKey: String { "chat.session." + (link.activePc()?.id ?? "-") }
    private var session: String {
        get { UserDefaults.standard.string(forKey: sessionKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: sessionKey) }
    }

    private func emit(_ message: [String: Any]) {
        deliver("window.__pbChat && window.__pbChat(\(jsonString(message)))")
    }

    static func sign(_ parts: [String], key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "\n").utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: from the page

    func setOpen(_ open: Bool) {
        visible = open
        updateTimer()
        if open { lastProjects = ""; Task { await checkReady(); await checkProjects() } }
    }

    /// Stops polling while the app is in the background; the page asks again when it is visible.
    func pause(_ paused: Bool) {
        if paused { timer?.invalidate(); timer = nil } else { updateTimer() }
    }

    func newChat() {
        session = ""
        pending = nil
    }

    func cancel() {
        guard pending != nil else { return }
        Task { await send(text: "", action: "cancel") }
    }

    func send(_ text: String) {
        let text = String(text.prefix(8000))
        guard !text.isEmpty, pending == nil else { return }
        Task { await send(text: text, action: "send") }
    }

    /// Switches Claude Code to another project folder: only one the Mac offered (it checks again).
    func selectFolder(_ path: String) {
        guard pending == nil, !path.isEmpty else { return }
        Task { await send(text: path, action: "folder") }
    }

    private func send(text: String, action: String) async {
        guard let pc = link.activePc() else { emit(["type": "error", "message": L("chat_not_paired")]); return }
        let id = UUID().uuidString.lowercased()
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let session = action == "folder" ? "" : self.session
        let body: [String: Any] = [
            "v": 2, "id": id, "ts": ts, "session": session, "text": text, "action": action,
            "sig": Self.sign(["req", id, ts, session, action, text], key: pc.token),
        ]
        let reply = await link.request(method: "POST", pathAndQuery: "/api/push/\(ChatProtocol.request)?ttl=120",
                                       body: jsonString(body).data(using: .utf8), contentType: "application/json")
        if action == "cancel" { return }
        guard reply.code == 200 else {
            emit(["type": "error", "message": reply.code == 503 ? L("chat_offline") : "HTTP \(reply.code)"])
            return
        }
        pending = id
        lastReply = ""
        emit(["type": action == "folder" ? "switching" : "sent", "id": id])
        updateTimer()
    }

    // MARK: polling

    private func updateTimer() {
        let want = visible || pending != nil
        if !want { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        tick += 1
        Task {
            if pending != nil { await checkReply() }
            if visible && tick % 6 == 1 { await checkReady(); await checkProjects() }
        }
    }

    private static func item(_ data: Data) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (json["data"] as? [String: Any]) ?? json
    }

    private func checkReady() async {
        guard let pc = link.activePc() else { emit(["type": "ready", "ok": false, "paired": false]); return }
        let r = await link.request(method: "GET", pathAndQuery: "/api/push/\(ChatProtocol.ready)")
        var ok = false
        var folder = ""
        if r.code == 200, let d = Self.item(r.body), let ts = d["ts"] as? String, let sig = d["sig"] as? String {
            folder = d["folder"] as? String ?? ""
            ok = Self.sign(["ready", ts, folder], key: pc.token) == sig
        }
        let state = "\(ok)|\(folder)"
        if state != lastReady || r.code == 503 {
            lastReady = state
            emit(["type": "ready", "ok": ok, "folder": folder])
        }
    }

    private var lastProjects = ""

    /// The project folders the Mac offers (pbchat.projects), signed like everything else.
    private func checkProjects() async {
        guard let pc = link.activePc() else { return }
        let r = await link.request(method: "GET", pathAndQuery: "/api/push/\(ChatProtocol.projects)")
        guard r.code == 200, let d = Self.item(r.body), let ts = d["ts"] as? String, let sig = d["sig"] as? String,
              let current = d["current"] as? String, let raw = d["items"] as? [[String: Any]] else { return }
        let items = raw.compactMap { item -> (String, String)? in
            guard let name = item["name"] as? String, let path = item["path"] as? String else { return nil }
            return (name, path)
        }
        let joined = items.map { $0.0 + "\u{1F}" + $0.1 }.joined(separator: "\u{1E}")
        guard Self.sign(["projects", ts, current, joined], key: pc.token) == sig else { return }
        let state = current + "|" + joined
        guard state != lastProjects else { return }
        lastProjects = state
        emit(["type": "projects", "current": current, "items": items.map { ["name": $0.0, "path": $0.1] }])
    }

    private func checkReply() async {
        guard let id = pending, let pc = link.activePc() else { return }
        let r = await link.request(method: "GET", pathAndQuery: "/api/push/\(ChatProtocol.reply)")
        guard r.code == 200, let d = Self.item(r.body), d["id"] as? String == id,
              let status = d["status"] as? String, let sig = d["sig"] as? String else { return }
        let text = d["text"] as? String ?? ""
        let session = d["session"] as? String ?? ""
        let tools = (d["tools"] as? [String]) ?? []
        // only replies from this computer's Starter, made with the same key
        guard Self.sign(["res", id, status, session, text, tools.joined(separator: "\u{1F}")], key: pc.token) == sig else { return }
        let fingerprint = "\(status)|\(text.count)|\(tools.count)|\(text.suffix(40))"
        guard fingerprint != lastReply else { return }
        lastReply = fingerprint
        if status == "folder" { self.session = ""; lastProjects = "" } else if !session.isEmpty { self.session = session }
        emit(["type": "reply", "id": id, "status": status, "text": text, "tools": tools])
        if status != "running" {
            pending = nil
            updateTimer()
        }
    }
}

enum ChatProtocol {
    static let request = "pbchat.req"
    static let reply = "pbchat.res"
    static let ready = "pbchat.ready"
    static let projects = "pbchat.projects"
}
