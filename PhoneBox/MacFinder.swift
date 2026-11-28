import Foundation

/// Lets the iPhone find the Mac again after the Mac got another address (another network, a new DHCP lease).
///
/// An address is all the pairing gives the phone, and it is only right in the network where it was made. The Mac's
/// Bonjour name ("<name>.local") is right in every network, but the pairing link does not carry it (the computer name
/// the agent reports follows the network). So PhoneBox Starter on the Mac announces it through the agent
/// (pbchat.host, signed with the phone's paired key) and this reads it while the phone is connected and keeps it next
/// to the addresses (AgentLink.learnHost). From then on the connection falls back to the name when the addresses
/// fail, and keeps using it once it works. Without PhoneBox Starter running while connected, nothing is learned and the
/// phone must be paired again after a network change, as before.
@MainActor
final class MacFinder {
    private let link: AgentLink
    private var timer: Timer?

    init(link: AgentLink) { self.link = link }

    func start() {
        guard timer == nil else { return }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() { Task { await check() } }

    private func check() async {
        guard let pc = link.activePc() else { return }
        let r = await link.request(method: "GET", pathAndQuery: "/api/push/pbchat.host")
        guard r.code == 200,
              let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let d = (json["data"] as? [String: Any]) ?? json as [String: Any]?,
              let host = d["host"] as? String, let ts = d["ts"] as? String, let sig = d["sig"] as? String else { return }
        guard ClaudeChat.sign(["host", ts, host], key: pc.token) == sig else { return } // only this computer's Starter
        link.learnHost(host, for: pc.id)
    }
}
