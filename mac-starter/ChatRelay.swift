import CryptoKit
import Foundation

/// Claude Code chat for the phone. The phone and this Mac talk through the PhoneBox agent's push store, over the
/// connection the phone already has (TLS pinned, paired key), so no extra port is opened:
///
///   phone  --POST /api/push/pbchat.req-->  agent  <--GET (local)--  Starter  --runs-->  claude -p
///   phone  <--GET  /api/push/pbchat.res--  agent  <--POST (local)-- Starter
///
/// Other machines may hold the agent's webhook key and could write to the push store too, so every request carries
/// an HMAC made with the phone's own paired key (which only the phone and this Mac know); anything else is ignored.
/// Replies are signed the same way, so the phone ignores replies it did not get from here.
final class ChatRelay: @unchecked Sendable {
    static let requestKey = "pbchat.req"
    static let replyKey = "pbchat.res"
    static let readyKey = "pbchat.ready"

    private let lock = NSLock()
    private var running = false
    private var process: Process?
    private var currentId: String?
    private var seen: [String] = []
    private var loop: Task<Void, Never>?

    /// The state above is read and changed from the polling task and the menu; these keep each access short and safe.
    private func isSeen(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return seen.contains(id) }
    private func markSeen(_ id: String) { lock.lock(); defer { lock.unlock() }; seen.append(id); if seen.count > 50 { seen.removeFirst() } }
    private func currentProcess() -> Process? { lock.lock(); defer { lock.unlock() }; return process }
    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func setRunning(_ p: Process?, id: String?) { lock.lock(); defer { lock.unlock() }; running = p != nil; process = p; currentId = id }

    var workingDirectory: () -> URL
    var allowEdits: () -> Bool

    init(workingDirectory: @escaping () -> URL, allowEdits: @escaping () -> Bool) {
        self.workingDirectory = workingDirectory
        self.allowEdits = allowEdits
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task.detached { [weak self] in
            var lastReady = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastReady) > 10 { lastReady = Date(); await self.announceReady() }
                await self.poll()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    func stop() {
        lock.lock()
        loop?.cancel()
        loop = nil
        let p = process
        lock.unlock()
        p?.terminate()
        Task { await Self.agent("DELETE", Self.readyKey) }
    }

    // MARK: agent push store (local port, which only answers this computer)

    @discardableResult
    static func agent(_ method: String, _ key: String, body: [String: Any]? = nil, ttl: Int? = nil) async -> [String: Any]? {
        var url = "http://127.0.0.1:8765/api/push/\(key)"
        if let ttl { url += "?ttl=\(ttl)" }
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 3)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The phone's paired key, from the agent's settings; nil while Wi-Fi pairing is off.
    static func phoneKey() -> String? {
        let config = AgentController.support.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let lan = (json["lan"] ?? json["Lan"]) as? [String: Any]
        guard (lan?["enabled"] as? Bool) == true, let token = lan?["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static func sign(_ parts: [String], key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "\n").utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func announceReady() async {
        guard let key = Self.phoneKey() else { return }
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let folder = workingDirectory().lastPathComponent
        await Self.agent("POST", Self.readyKey, body: ["v": 1, "ts": ts, "folder": folder, "sig": Self.sign(["ready", ts, folder], key: key)], ttl: 25)
    }

    // MARK: requests

    private func poll() async {
        guard let item = await Self.agent("GET", Self.requestKey) else { return }
        let request = (item["data"] as? [String: Any]) ?? item
        guard let key = Self.phoneKey(),
              let id = request["id"] as? String, let ts = request["ts"] as? String, let sig = request["sig"] as? String else { return }
        let text = request["text"] as? String ?? ""
        let session = request["session"] as? String ?? ""
        let cancel = (request["cancel"] as? Bool) == true
        if isSeen(id) { return }
        // only the paired phone, and only a fresh request (a copy replayed later is refused)
        let expected = Self.sign(["req", id, ts, session, cancel ? "1" : "0", text], key: key)
        let age = Date().timeIntervalSince1970 * 1000 - (Double(ts) ?? 0)
        await Self.agent("DELETE", Self.requestKey)
        guard expected == sig, abs(age) < 120_000 else { return }
        markSeen(id)

        if cancel {
            currentProcess()?.terminate()
            return
        }
        if isRunning() {
            await reply(id: id, session: session, status: "error", text: "Claude Code arbeitet noch an der letzten Nachricht.", tools: [], key: key)
            return
        }
        await run(id: id, text: text, session: session, key: key)
    }

    private func reply(id: String, session: String, status: String, text: String, tools: [String], key: String) async {
        // the push store takes 64 KB: keep the end of a very long answer
        var body = text
        if body.utf8.count > 40_000 { body = "…" + String(body.suffix(30_000)) }
        let list = Array(tools.suffix(30))
        let sig = Self.sign(["res", id, status, session, body, list.joined(separator: "\u{1F}")], key: key)
        await Self.agent("POST", Self.replyKey,
                         body: ["v": 1, "id": id, "status": status, "session": session, "text": body, "tools": list, "sig": sig], ttl: 900)
    }

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(id: String, text: String, session: String, key: String) async {
        guard let claude = Self.claudePath() else {
            await reply(id: id, session: session, status: "error", text: "Claude Code ist auf diesem Mac nicht installiert.", tools: [], key: key)
            return
        }
        var arguments = ["-p", text, "--output-format", "stream-json", "--verbose"]
        if !session.isEmpty { arguments += ["--resume", session] }
        if allowEdits() { arguments += ["--permission-mode", "acceptEdits"] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        setRunning(process, id: id)
        defer { setRunning(nil, id: nil) }

        var sessionId = session
        var answer = ""
        var tools: [String] = []
        var finalText: String?
        var failed = false
        do { try process.run() } catch {
            await reply(id: id, session: session, status: "error", text: "Claude Code ließ sich nicht starten: \(error.localizedDescription)", tools: [], key: key)
            return
        }
        await reply(id: id, session: sessionId, status: "running", text: "", tools: [], key: key)

        var lastSent = Date()
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                if let s = event["session_id"] as? String, !s.isEmpty { sessionId = s }
                switch event["type"] as? String {
                case "assistant":
                    let content = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                    for block in content {
                        if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty {
                            answer += (answer.isEmpty ? "" : "\n\n") + t
                        } else if block["type"] as? String == "tool_use" {
                            tools.append(Self.describe(tool: block["name"] as? String ?? "?", input: block["input"] as? [String: Any] ?? [:]))
                        }
                    }
                case "result":
                    finalText = event["result"] as? String
                    failed = (event["is_error"] as? Bool) == true
                default: break
                }
                if Date().timeIntervalSince(lastSent) > 0.8 {
                    lastSent = Date()
                    await reply(id: id, session: sessionId, status: "running", text: answer, tools: tools, key: key)
                }
            }
        } catch {}
        process.waitUntilExit()
        let text = (finalText?.isEmpty == false ? finalText! : answer)
        if process.terminationReason == .uncaughtSignal {
            await reply(id: id, session: sessionId, status: "stopped", text: answer, tools: tools, key: key)
        } else if failed || (process.terminationStatus != 0 && text.isEmpty) {
            await reply(id: id, session: sessionId, status: "error", text: text.isEmpty ? "Claude Code hat einen Fehler gemeldet." : text, tools: tools, key: key)
        } else {
            await reply(id: id, session: sessionId, status: "done", text: text, tools: tools, key: key)
        }
    }

    /// One short line per tool Claude used ("Read · notes.md"), shown under its answer on the phone.
    static func describe(tool: String, input: [String: Any]) -> String {
        let detail = ["file_path", "path", "pattern", "command", "url", "query", "description"]
            .compactMap { input[$0] as? String }.first ?? ""
        let short = detail.count > 70 ? String(detail.prefix(70)) + "…" : detail
        return short.isEmpty ? tool : "\(tool) · \((short as NSString).lastPathComponent == short ? short : short)"
    }
}
