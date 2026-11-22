import Foundation

/// Keeps one live connection to the agent's /api/stream (server-sent events) and hands every event to `deliver`.
/// Reconnects after errors, and every minute so a changed address list is picked up. "open" / "close" pseudo-events tell
/// the panel when to stop or resume its polling fallback (see AgentStream.kt).
final class AgentStream: @unchecked Sendable {
    private let link: AgentLink
    private let deliver: @MainActor (String, String) -> Void
    private let gate = NSLock()
    private var task: Task<Void, Never>?
    private var generation = 0

    init(link: AgentLink, deliver: @escaping @MainActor (String, String) -> Void) {
        self.link = link
        self.deliver = deliver
    }

    func start() {
        gate.lock(); defer { gate.unlock() }
        if task != nil { return }
        generation += 1
        let gen = generation
        task = Task.detached { [self] in await loop(gen) }
    }

    func stop() {
        gate.lock()
        generation += 1
        let running = task
        task = nil
        gate.unlock()
        running?.cancel()
    }

    private func alive(_ gen: Int) -> Bool {
        gate.lock(); defer { gate.unlock() }
        return task != nil && gen == generation && !Task.isCancelled
    }

    /// Delivers only while generation [gen] is current, so nothing arrives after stop() returned.
    private func dispatch(_ gen: Int, _ event: String, _ data: String) async {
        await MainActor.run { if alive(gen) { deliver(event, data) } }
    }

    private func loop(_ gen: Int) async {
        while alive(gen) {
            var opened = false
            do {
                guard let (route, bytes, response) = await link.stream("/api/stream") else { throw URLError(.notConnectedToInternet) }
                if response.statusCode != 200 { throw URLError(.badServerResponse) }
                if !alive(gen) { break }
                opened = true
                await dispatch(gen, "open", #"{"route":"\#(route.rawValue)"}"#)
                let since = Date()
                var event = "message"
                var data = ""
                var line = [UInt8]()
                // not bytes.lines: that skips the empty lines which end an event
                read: for try await byte in bytes {
                    if !alive(gen) { break }
                    if byte != 0x0A { line.append(byte); continue }
                    if line.last == 0x0D { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll(keepingCapacity: true)
                    if text.isEmpty {
                        if !data.isEmpty { await dispatch(gen, event, data) }
                        event = "message"
                        data = ""
                        if Date().timeIntervalSince(since) > 60 { break read }
                    } else if text.hasPrefix("event:") {
                        event = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    } else if text.hasPrefix("data:") {
                        data += String(text.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " \t"))
                    }
                }
            } catch {
                // fall through: reconnect
            }
            if opened && alive(gen) { await dispatch(gen, "close", "{}") }
            if alive(gen) { try? await Task.sleep(nanoseconds: opened ? 300_000_000 : 2_000_000_000) }
        }
    }
}
