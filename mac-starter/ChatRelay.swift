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
    static let projectsKey = "pbchat.projects"

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
    /// Claude answers in German whatever language the message or the files are in (on by default).
    var germanOnly: () -> Bool = { (UserDefaults.standard.object(forKey: "chatGerman") as? Bool) ?? true }
    /// The phone picked another project folder (it is already stored in the defaults).
    var onFolderChange: ((URL) -> Void)?

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
        Task {
            await Self.agent("DELETE", Self.readyKey)
            await Self.agent("DELETE", Self.projectsKey)
        }
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

    /// The name this Mac answers to on any network ("Mein-MacBook.local"), which the iPhone learns over its
    /// connection and tries when the Mac's address has changed. It is the sharing name from System Settings, not the
    /// computer name the agent reports (that one follows the network's DHCP name).
    static func localHostName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.range(of: "^[A-Za-z0-9-]{1,63}$", options: .regularExpression) != nil ? name + ".local" : nil
    }

    /// Signed with the phone's key like everything else here, so only this Mac's Starter can tell the phone a host name.
    static func announceHost() async {
        guard let key = phoneKey(), let host = localHostName() else { return }
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        await agent("POST", "pbchat.host", body: ["v": 1, "ts": ts, "host": host, "sig": sign(["host", ts, host], key: key)], ttl: 90)
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
        await announceProjects(key: key)
    }

    // MARK: project folders

    /// The folders whose subfolders are projects: set in the menu, otherwise ~/CEO when it exists, else the home folder.
    static func projectRoots() -> [URL] {
        if let paths = UserDefaults.standard.stringArray(forKey: "projectRoots"), !paths.isEmpty { return paths.map { URL(fileURLWithPath: $0) } }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ceo = home.appendingPathComponent("CEO")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: ceo.path, isDirectory: &isDir) && isDir.boolValue ? [ceo] : [home]
    }

    /// The folders Claude Code was used in lately, from its own history (~/.claude/projects): the "cwd" of the newest
    /// conversation of each project. Only that field is read.
    static func recentClaudeFolders() -> [(URL, Date)] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var found: [(URL, Date)] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let newest = files.filter { $0.pathExtension == "jsonl" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .max { $0.1 < $1.1 }
            guard let (file, date) = newest, let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = handle.readData(ofLength: 256 * 1024)
            try? handle.close()
            for line in head.split(separator: UInt8(ascii: "\n")).prefix(200) {
                if let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let cwd = json["cwd"] as? String {
                    found.append((URL(fileURLWithPath: cwd), date))
                    break
                }
            }
        }
        return found
    }

    /// The project folders the phone may choose from: the newest first, the current folder always among them.
    static func projects(current: URL) -> [(name: String, path: String)] {
        let fm = FileManager.default
        var dates: [String: Date] = [:]
        for (url, date) in recentClaudeFolders() { dates[url.standardizedFileURL.path] = max(dates[url.standardizedFileURL.path] ?? .distantPast, date) }
        for root in projectRoots() {
            let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for sub in subs {
                let values = try? sub.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else { continue }
                let path = sub.standardizedFileURL.path
                dates[path] = max(dates[path] ?? .distantPast, values?.contentModificationDate ?? .distantPast)
            }
        }
        dates[current.standardizedFileURL.path] = max(dates[current.standardizedFileURL.path] ?? .distantPast, Date())
        let paths = dates.filter { path, _ in
            var isDir: ObjCBool = false
            // app data folders (scratch workspaces and the like) are not projects
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue && !path.contains("/Library/") && !path.contains("/.")
        }.sorted { $0.value > $1.value }.prefix(40).map(\.key)
        let names = paths.map { ($0 as NSString).lastPathComponent }
        return paths.enumerated().map { index, path in
            let name = names[index]
            // the same name twice: show the parent folder as well
            let unique = names.filter { $0 == name }.count == 1
            return (unique ? name : ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + name, path)
        }
    }

    static func projectsSignature(ts: String, current: String, items: [(name: String, path: String)], key: String) -> String {
        sign(["projects", ts, current, items.map { $0.name + "\u{1F}" + $0.path }.joined(separator: "\u{1E}")], key: key)
    }

    private func announceProjects(key: String) async {
        let current = workingDirectory().standardizedFileURL.path
        let items = Self.projects(current: workingDirectory())
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        await Self.agent("POST", Self.projectsKey, body: [
            "v": 2, "ts": ts, "current": current, "items": items.map { ["name": $0.name, "path": $0.path] },
            "sig": Self.projectsSignature(ts: ts, current: current, items: items, key: key),
        ], ttl: 40)
    }

    // MARK: requests

    private func poll() async {
        guard let item = await Self.agent("GET", Self.requestKey) else { return }
        let request = (item["data"] as? [String: Any]) ?? item
        guard let key = Self.phoneKey(),
              let id = request["id"] as? String, let ts = request["ts"] as? String, let sig = request["sig"] as? String else { return }
        let text = request["text"] as? String ?? ""
        let session = request["session"] as? String ?? ""
        let action = request["action"] as? String ?? "send"   // send, cancel or folder
        if isSeen(id) { return }
        // only the paired phone, and only a fresh request (a copy replayed later is refused)
        let expected = Self.sign(["req", id, ts, session, action, text], key: key)
        let age = Date().timeIntervalSince1970 * 1000 - (Double(ts) ?? 0)
        await Self.agent("DELETE", Self.requestKey)
        guard expected == sig, abs(age) < 120_000 else { return }
        markSeen(id)

        if action == "cancel" {
            currentProcess()?.terminate()
            return
        }
        if action == "folder" {
            await switchFolder(id: id, path: text, key: key)
            return
        }
        if isRunning() {
            await reply(id: id, session: session, status: "error", text: "Claude Code arbeitet noch an der letzten Nachricht.", tools: [], key: key)
            return
        }
        await run(id: id, text: text, session: session, key: key)
    }

    /// The phone picked a project folder. Only a folder from the list this Mac offers is taken, never any other path.
    private func switchFolder(id: String, path: String, key: String) async {
        let offered = Self.projects(current: workingDirectory())
        guard let match = offered.first(where: { $0.path == path }) else {
            await reply(id: id, session: "", status: "error", text: "Diesen Ordner bietet der Mac nicht an.", tools: [], key: key)
            return
        }
        if isRunning() {
            await reply(id: id, session: "", status: "error", text: "Claude Code arbeitet noch – erst danach den Ordner wechseln.", tools: [], key: key)
            return
        }
        let url = URL(fileURLWithPath: match.path)
        UserDefaults.standard.set(url, forKey: "chatFolder")
        onFolderChange?(url)
        // a conversation belongs to its folder: the phone starts a new one
        await reply(id: id, session: "", status: "folder", text: match.name, tools: [match.path], key: key)
        await announceReady()
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
        if germanOnly() {
            arguments += ["--append-system-prompt",
                          "Antworte ausnahmslos auf Deutsch – auch wenn der Nutzer in einer anderen Sprache schreibt, "
                          + "um eine andere Sprache bittet oder Code, Dateien und Ausgaben in einer anderen Sprache sind. "
                          + "Code, Befehle, Dateinamen und Fehlermeldungen gibst du unverändert wieder."]
        }

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
