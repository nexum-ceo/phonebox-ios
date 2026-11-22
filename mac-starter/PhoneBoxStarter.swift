import AppKit
import ServiceManagement
import SwiftUI

/// PhoneBox Starter: a small menu bar app for the Mac that starts, stops and restarts the PhoneBox agent (the server the
/// phone connects to) and shows whether it is running.
/// Without arguments the menu bar app; with --start, --stop, --restart or --status a command for the Terminal or the
/// Shortcuts app ("Run Shell Script"), e.g. "PhoneBox Starter.app/Contents/MacOS/PhoneBoxStarter" --stop
@main
enum Entry {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? ""
        guard ["--start", "--stop", "--restart", "--status"].contains(command) else { PhoneBoxStarterApp.main(); return }
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            switch command {
            case "--start": await AgentController.startAgent()
            case "--stop": await AgentController.stopAgent()
            case "--restart": await AgentController.stopAgent(); await AgentController.startAgent()
            default: break
            }
            let running = await AgentController.info() != nil
            print(running ? "PhoneBox läuft" : "PhoneBox gestoppt")
            code = (command == "--stop") == running ? 1 : 0
            done.signal()
        }
        done.wait()
        exit(code)
    }
}

struct PhoneBoxStarterApp: App {
    @StateObject private var agent = AgentController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(agent: agent)
        } label: {
            Image(systemName: agent.state.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var agent: AgentController

    var body: some View {
        Text(agent.state.title)
        if let version = agent.version, agent.state == .running { Text("Version \(version)") }
        Divider()
        Button("Starten") { agent.start() }
            .disabled(agent.state == .running || agent.state == .busy || agent.state == .notInstalled)
            .keyboardShortcut("s")
        Button("Stoppen") { agent.stop() }
            .disabled(agent.state == .stopped || agent.state == .busy || agent.state == .notInstalled)
            .keyboardShortcut("x")
        Button("Neu starten") { agent.restart() }
            .disabled(agent.state == .busy || agent.state == .notInstalled)
            .keyboardShortcut("r")
        Divider()
        Button("Einstellungen öffnen") { NSWorkspace.shared.open(AgentController.settingsURL) }
            .disabled(agent.state != .running)
            .keyboardShortcut(",")
        Button("Log anzeigen") { NSWorkspace.shared.open(AgentController.logURL) }
        Divider()
        Toggle("Claude-Chat fürs iPhone", isOn: $agent.chatEnabled)
        Button("Chat-Ordner: \(agent.chatFolder.lastPathComponent) …") { agent.chooseChatFolder() }
            .disabled(!agent.chatEnabled)
        Toggle("Claude darf Dateien bearbeiten", isOn: $agent.chatAllowEdits)
            .disabled(!agent.chatEnabled)
        if agent.chatEnabled && ChatRelay.claudePath() == nil { Text("Claude Code ist nicht installiert") }
        Divider()
        Toggle("Agent beim Öffnen starten", isOn: $agent.startOnLaunch)
        Toggle("Starter beim Anmelden öffnen", isOn: Binding(get: { agent.openAtLogin }, set: { agent.setOpenAtLogin($0) }))
        Divider()
        Button("Starter beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AgentController: ObservableObject {
    enum State: Equatable {
        case running, stopped, busy, notInstalled

        var title: String {
            switch self {
            case .running: return "● PhoneBox läuft"
            case .stopped: return "○ PhoneBox gestoppt"
            case .busy: return "… bitte warten"
            case .notInstalled: return "PhoneBox ist nicht installiert"
            }
        }

        var symbol: String {
            switch self {
            case .running: return "iphone.gen3.radiowaves.left.and.right"
            case .stopped: return "iphone.gen3.slash"
            case .busy: return "hourglass"
            case .notInstalled: return "exclamationmark.triangle"
            }
        }
    }

    nonisolated static let settingsURL = URL(string: "http://127.0.0.1:8765")!
    nonisolated static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PhoneBox")
    nonisolated static let binary = support.appendingPathComponent("app/PhoneBoxAgent")
    nonisolated static let logURL = support.appendingPathComponent("agent.log")
    /// The login item setup.sh writes when "start at login" was chosen; with it, launchd keeps the agent alive.
    nonisolated static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/net.oxog.phonebox.agent.plist")

    @Published private(set) var state: State = .busy
    @Published private(set) var version: String?
    @Published var startOnLaunch: Bool = UserDefaults.standard.bool(forKey: "startOnLaunch") {
        didSet { UserDefaults.standard.set(startOnLaunch, forKey: "startOnLaunch") }
    }
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    // MARK: Claude chat for the phone (see ChatRelay)

    @Published var chatEnabled: Bool = (UserDefaults.standard.object(forKey: "chatEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(chatEnabled, forKey: "chatEnabled"); chatEnabled ? relay.start() : relay.stop() }
    }
    /// Off by default: Claude may read and answer, but changing files needs this (or an approval on the phone when
    /// PhoneBox's Claude Code hook is installed).
    @Published var chatAllowEdits: Bool = UserDefaults.standard.bool(forKey: "chatAllowEdits") {
        didSet { UserDefaults.standard.set(chatAllowEdits, forKey: "chatAllowEdits") }
    }
    @Published var chatFolder: URL = UserDefaults.standard.url(forKey: "chatFolder") ?? FileManager.default.homeDirectoryForCurrentUser {
        didSet { UserDefaults.standard.set(chatFolder, forKey: "chatFolder") }
    }
    private lazy var relay = ChatRelay(
        // read from the defaults, not from this object: the relay asks from its own task, off the main actor
        workingDirectory: { UserDefaults.standard.url(forKey: "chatFolder") ?? FileManager.default.homeDirectoryForCurrentUser },
        allowEdits: { UserDefaults.standard.bool(forKey: "chatAllowEdits") })

    func chooseChatFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = chatFolder
        panel.message = "In welchem Ordner soll Claude Code arbeiten?"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { chatFolder = url }
    }

    private var timer: Timer?
    private var working = false

    init() {
        if chatEnabled { relay.start() }
        Task {
            await refresh()
            if startOnLaunch && state == .stopped { start() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: status

    func refresh() async {
        guard !working else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else { state = .notInstalled; return }
        if let info = await Self.info() {
            version = info["version"] as? String
            state = .running
        } else {
            version = nil
            state = Self.processRunning() ? .busy : .stopped // a running process that does not answer yet is starting
        }
    }

    /// The agent's /api/info, which only answers on this computer.
    nonisolated static func info() async -> [String: Any]? {
        var request = URLRequest(url: settingsURL.appendingPathComponent("api/info"), timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func processRunning() -> Bool { run("/usr/bin/pgrep", ["-x", "PhoneBoxAgent"]) == 0 }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: actions

    func start() {
        perform { await Self.startAgent() }
    }

    func stop() {
        perform { await Self.stopAgent() }
    }

    func restart() {
        perform {
            await Self.stopAgent()
            await Self.startAgent()
        }
    }

    private func perform(_ action: @escaping () async -> Void) {
        guard !working else { return }
        working = true
        state = .busy
        Task {
            await action()
            working = false
            await refresh()
        }
    }

    /// Like setup.sh: through launchd when the login item exists (it keeps the agent alive), otherwise as its own
    /// background process that keeps running when the Starter quits.
    nonisolated static func startAgent() async {
        if FileManager.default.fileExists(atPath: plist.path) {
            run("/bin/launchctl", ["load", plist.path])
        } else if !processRunning() {
            run("/bin/sh", ["-c", "nohup \"$0\" >/dev/null 2>&1 &", binary.path])
        }
        // wait until it answers (up to 20 s)
        for _ in 0..<40 {
            if await info() != nil { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    nonisolated static func stopAgent() async {
        // launchd would start it again (KeepAlive), so unload its job first
        if FileManager.default.fileExists(atPath: plist.path) { run("/bin/launchctl", ["unload", plist.path]) }
        run("/usr/bin/pkill", ["-x", "PhoneBoxAgent"])
        for _ in 0..<40 where processRunning() { try? await Task.sleep(nanoseconds: 250_000_000) }
        if processRunning() { run("/usr/bin/pkill", ["-9", "-x", "PhoneBoxAgent"]) }
    }

    // MARK: login item

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Anmeldeobjekt konnte nicht geändert werden"
            alert.informativeText = "Liegt der Starter im Ordner „Programme“? \(error.localizedDescription)"
            alert.runModal()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
