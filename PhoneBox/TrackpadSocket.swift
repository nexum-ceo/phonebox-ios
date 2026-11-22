import Foundation

/// A WebSocket to /api/trackpad on the computer for low-latency pointer events (TrackpadSocket in AgentLink.kt).
/// `send` returns false when the socket is not open, so the caller falls back to HTTP; it also starts a connection.
final class TrackpadSocket: @unchecked Sendable {
    private weak var link: AgentLink?
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var open = false
    private var connecting = false
    private var lastAttempt = Date.distantPast
    private var attempts = 0

    init(link: AgentLink) { self.link = link }

    func send(type: String, dx: Float, dy: Float, delta: Float) -> Bool {
        lock.lock()
        let socket = task
        let isOpen = open
        lock.unlock()
        if let socket, isOpen {
            let json = #"{"type":"\#(type)","dx":\#(dx),"dy":\#(dy),"delta":\#(delta)}"#
            if json.utf8.count <= 125 {
                socket.send(.string(json)) { [weak self] error in if error != nil { self?.close() } }
                return true
            }
            return false
        }
        ensureConnected()
        return false
    }

    func ensureConnected() {
        lock.lock()
        if connecting || open || Date().timeIntervalSince(lastAttempt) < 3 { lock.unlock(); return }
        guard let pc = link?.activePc(), let link else { lock.unlock(); return }
        connecting = true
        lastAttempt = Date()
        lock.unlock()
        // each attempt tries the next address of the computer, so a dead first address does not block the others
        let host = pc.hosts.isEmpty ? "" : pc.hosts[attempts % pc.hosts.count]
        attempts += 1
        repeat {
            guard !host.isEmpty, let url = URL(string: "wss://\(host):\(pc.port)/api/trackpad") else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(pc.token)", forHTTPHeaderField: "Authorization")
            let delegate = PinDelegate(pin: pc.id)
            let session = link.makeSession(pin: pc.id, delegate: delegate)
            let task = session.webSocketTask(with: request)
            delegate.onOpen = { [weak self, weak task] in
                guard let self, let task else { return }
                self.lock.lock()
                if self.link?.activePc()?.id == pc.id { self.task = task; self.session = session; self.open = true; self.connecting = false }
                else { task.cancel(with: .goingAway, reason: nil) }
                self.lock.unlock()
                self.listen(task)
            }
            delegate.onClose = { [weak self, weak task] in
                guard let self else { return }
                self.lock.lock()
                if self.task === task || self.task == nil { self.open = false; self.task = nil }
                self.connecting = false
                self.lock.unlock()
            }
            task.resume()
            return // the open/close callbacks say how it went; the next send tries again after a pause
        } while false
        lock.lock(); connecting = false; lock.unlock()
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success: self.listen(task) // incoming frames are ignored
            case .failure: self.close(task)
            }
        }
    }

    func close(_ target: URLSessionWebSocketTask? = nil) {
        lock.lock()
        let current = task
        if target == nil || current === target {
            task = nil
            open = false
            connecting = false
            lock.unlock()
            current?.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
            session = nil
            return
        }
        lock.unlock()
    }
}
