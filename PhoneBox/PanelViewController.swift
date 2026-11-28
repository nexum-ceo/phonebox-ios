import AVFoundation
import CoreHaptics
import MediaPlayer
import UIKit
import WebKit

/// Full-screen desk panel (the iOS counterpart of MainActivity.kt). The UI is the unchanged HTML/JS panel bundled in
/// www/. The panel calls "/agent/..." URLs; they are intercepted by PanelSchemeHandler and forwarded to the PhoneBox
/// agent on the computer (AgentLink). The panel's native bridge (`window.Android`) is provided by BridgeScript.
@MainActor
final class PanelViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

    private let link = AgentLink()
    private var web: WKWebView!
    private var handler: PanelSchemeHandler!
    private var stream: AgentStream!
    private var dictation: Dictation!
    private var chat: ClaudeChat!
    private lazy var standby = PowerStandby(link: link)
    private lazy var finder = MacFinder(link: link)
    private let bridgeKey = UUID().uuidString
    private var resumed = false
    private var orientationMode = "landscape"
    private var volumeKeysFlipPages = true
    private var volume: VolumeKeys!
    private var haptics: CHHapticEngine?
    private var systemBrightness: CGFloat = UIScreen.main.brightness
    private var brightnessOverride: CGFloat?
    private var proximityAvailable = false
    private var pairing = false

    // MARK: view

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true // FLAG_KEEP_SCREEN_ON

        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? audio.setActive(true)

        handler = PanelSchemeHandler(link: link)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: PanelSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(WeakScriptHandler(self), name: "phonebox")

        web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.navigationDelegate = self
        web.uiDelegate = self
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true } // Safari > Develop > [iPhone]
        #endif
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Android's Back (button or edge swipe): an iPhone has no Back button, so a swipe in from the left or right edge
        for edge in [UIRectEdge.left, .right] {
            let back = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backGesture(_:)))
            back.edges = edge
            back.delegate = self
            view.addGestureRecognizer(back)
        }

        stream = AgentStream(link: link) { [weak self] event, data in
            self?.run("window.onAgentStream && window.onAgentStream(\(jsQuote(event)), \(jsQuote(data)))")
        }
        dictation = Dictation { [weak self] script in self?.run(script) }
        chat = ClaudeChat(link: link) { [weak self] script in self?.run(script) }
        volume = VolumeKeys(host: view) { [weak self] key in self?.run("window.onAndroidKey && window.onAndroidKey('\(key)')") }

        UIDevice.current.isBatteryMonitoringEnabled = true
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityAvailable = UIDevice.current.isProximityMonitoringEnabled
        UIDevice.current.isProximityMonitoringEnabled = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(proximityChanged), name: UIDevice.proximityStateDidChangeNotification, object: nil)

        canListen = dictation.available()
        installBridgeScript()
        web.load(URLRequest(url: PanelSchemeHandler.startURL))
    }

    @objc private func backGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let travel = gesture.translation(in: view).x
        guard abs(travel) > 40 else { return } // a real swipe, not a touch at the edge
        run("window.onAndroidBack && window.onAndroidBack()")
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: state shown to the panel

    private var canListen = false
    private var lastState = ""
    private var stateTimer: Timer?

    /// What the panel reads synchronously from `window.Android` (see BridgeScript).
    private func stateJson() -> String {
        jsonString([
            "battery": batteryJson(), "pcs": link.pcsJson(), "transport": link.route.rawValue, "canWake": link.canWake(),
            "canListen": canListen, "sensors": jsonString(["light": false, "proximity": proximityAvailable]),
            "version": DeviceInfo.appVersion,
            "is24Hour": !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? "").contains("a"),
        ] as [String: Any])
    }

    /// The bridge script carries the state at the time of the load, so it is made again before every load.
    private func installBridgeScript() {
        let state = stateJson()
        lastState = state
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        let script = BridgeScript.source(key: bridgeKey, languages: Locale.preferredLanguages, state: state)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: ChatScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private func pushState() {
        let state = stateJson()
        guard state != lastState else { return }
        lastState = state
        run("window.__pbSet && window.__pbSet(\(state))")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch orientationMode {
        case "portrait": return .portrait
        case "auto": return .allButUpsideDown
        default: return .landscape
        }
    }

    private func run(_ script: String) { web?.evaluateJavaScript(script, completionHandler: nil) }

    // MARK: lifecycle

    @objc private func didBecomeActive() {
        resumed = true
        run("window.onAppPause && window.onAppPause(false)") // the panel catches up at once
        stream.start()
        chat.pause(false)
        standby.setActive(true)
        finder.start()
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pushState() } }
        updateProximity()
        systemBrightness = UIScreen.main.brightness
        if let brightnessOverride { UIScreen.main.brightness = brightnessOverride }
        volume.setEnabled(volumeKeysFlipPages)
    }

    @objc private func willResignActive() {
        resumed = false
        stateTimer?.invalidate()
        stateTimer = nil
        standby.setActive(false)
        finder.stop()
        chat.pause(true)
        dictation.cancel(0) // the microphone is never left open behind another app or a dark screen
        stream.stop()
        run("window.onAppPause && window.onAppPause(true)") // tell the panel to stop polling and refreshing while nobody sees it
        UIDevice.current.isProximityMonitoringEnabled = false
        if brightnessOverride != nil { UIScreen.main.brightness = systemBrightness } // the system setting is not ours to keep
        volume.setEnabled(false)
    }

    /// Android only reports the proximity sensor; iOS also switches the screen off while something is near it. So the
    /// sensor is watched only while the panel is dark (night screen or dimmed), the only time the panel uses it (a wave
    /// of the hand wakes the night screen); a lit panel never goes black because a hand or a stand is close.
    private func updateProximity() {
        let dark = (brightnessOverride ?? 1) <= 0.15
        let on = proximityAvailable && resumed && dark
        if UIDevice.current.isProximityMonitoringEnabled != on { UIDevice.current.isProximityMonitoringEnabled = on }
    }

    @objc private func proximityChanged() {
        guard resumed else { return }
        run("window.onAndroidSensor && window.onAndroidSensor('proximity', \(UIDevice.current.proximityState))")
    }

    // MARK: bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let method = body["method"] as? String,
              var args = body["args"] as? [Any], let key = args.first as? String else { return }
        args.removeFirst()
        _ = call(method, key: key, args: args)
    }

    private func number(_ any: Any?) -> Double {
        let value = (any as? NSNumber)?.doubleValue ?? 0
        return value.isFinite ? value : 0
    }

    private static let trackpadTypes: Set<String> = ["move", "click", "rightClick", "mousedown", "mouseup", "scroll", "hscroll",
        "swipe3up", "swipe3down", "swipe3left", "swipe3right", "swipe4up", "swipe4down", "swipe4left", "swipe4right", "spread", "pinch"]

    /// The methods of Android's `Bridge` class. Calls without the panel's key do nothing (fail closed).
    private func call(_ method: String, key: String, args: [Any]) -> Any? {
        guard key == bridgeKey else { return nil }
        switch method {
        case "trackpad":
            guard let type = args.first as? String, Self.trackpadTypes.contains(type), args.count >= 4 else { return nil }
            link.sendTrackpad(type: type, dx: Float(number(args[1])), dy: Float(number(args[2])), delta: Float(number(args[3])))
        case "setLanguage":
            if let tag = args.first as? String, tag.range(of: "^(auto|[a-z]{2}(-[A-Za-z]{2,4})?)$", options: .regularExpression) != nil {
                LocalizedStrings.use(panelLanguage: tag)
            }
        case "setBrightness":
            let value = CGFloat(number(args.first))
            if value < 0 { brightnessOverride = nil; UIScreen.main.brightness = systemBrightness }
            else { brightnessOverride = min(max(value, 0.01), 1); if resumed { UIScreen.main.brightness = brightnessOverride! } }
            updateProximity()
        case "chatOpen":
            chat.setOpen((args.first as? Bool) ?? ((args.first as? NSNumber)?.boolValue ?? false))
        case "chatSend":
            if let text = args.first as? String { chat.send(text) }
        case "chatCancel":
            chat.cancel()
        case "chatNew":
            chat.newChat()
        case "chatFolder":
            if let path = args.first as? String { chat.selectFolder(path) }
        case "log":
            if let text = args.first as? String { NSLog("PhoneBoxWeb %@", text) }
        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "buzz":
            if let pattern = args.first as? String { buzz(pattern) }
        case "setVolumeKeys":
            volumeKeysFlipPages = (args.first as? Bool) ?? ((args.first as? NSNumber)?.boolValue ?? true)
            volume.setEnabled(volumeKeysFlipPages && resumed)
        case "setStandby":
            // (mode, graceSec): the panel pushes display.standby with its settings
            standby.configure(mode: (args.first as? String) ?? "off", graceSeconds: args.count > 1 ? Int(number(args[1])) : 30)
        case "setPinned", "setHomeScreen":
            break // Guided Access and a home-screen app cannot be turned on by an app (kiosk: Settings > Accessibility > Guided Access)
        case "selectPc":
            if let id = args.first as? String, link.select(id) { restart() }
        case "forgetPc":
            if let id = args.first as? String { link.forget(id); pushState() }
        case "wakePc":
            if let id = args.first as? String { _ = link.wake(id) }
        case "setOrientation":
            if let mode = args.first as? String { setOrientation(mode) }
        case "listen":
            // (lang, offline, id): the id was made by the page
            guard args.count >= 3, let id = (args[2] as? NSNumber)?.intValue, id > 0 else { return nil }
            let lang = ((args[0] as? String) ?? "").prefix(20).filter { $0.isLetter || $0.isNumber || $0 == "-" }
            dictation.start(id: id, lang: String(lang), offline: (args[1] as? NSNumber)?.boolValue ?? false)
        case "stopListening":
            if let id = (args.first as? NSNumber)?.intValue, id > 0 { dictation.stop(id) }
        case "cancelListening":
            if let id = (args.first as? NSNumber)?.intValue, id > 0 { dictation.cancel(id) }
        default: break
        }
        return nil
    }

    private func batteryJson() -> String {
        let device = UIDevice.current
        let level = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : -1
        let plugged = device.batteryState == .charging || device.batteryState == .full
        return jsonString(["level": level, "plugged": plugged, "temp": 0, "source": plugged ? "ac" : "", "usb": NSNull()] as [String: Any])
    }

    /// Notification vibration; pattern is a "wait,vibrate,wait,vibrate..." list of milliseconds.
    private func buzz(_ pattern: String) {
        let timings = pattern.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !timings.isEmpty else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        var events: [CHHapticEvent] = []
        var time = 0.0
        for (index, ms) in timings.enumerated() {
            let seconds = max(ms, 0) / 1000
            if index % 2 == 1, seconds > 0 {
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1), CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ], relativeTime: time, duration: min(seconds, 30)))
            }
            time += seconds
        }
        guard !events.isEmpty else { return }
        do {
            if haptics == nil {
                haptics = try CHHapticEngine()
                haptics?.resetHandler = { [weak self] in try? self?.haptics?.start() }
                haptics?.stoppedHandler = { [weak self] _ in self?.haptics = nil }
            }
            try haptics?.start()
            let player = try haptics?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    private func setOrientation(_ mode: String) {
        let wanted = ["portrait", "auto"].contains(mode) ? mode : "landscape"
        guard wanted != orientationMode else { return }
        orientationMode = wanted
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { _ in }
        }
    }

    /// Reloads the panel from the (newly selected) computer.
    private func restart() {
        installBridgeScript()
        stream.stop()
        if resumed { stream.start() }
        web.reload()
    }

    // MARK: pairing

    func handlePairingURL(_ url: URL) {
        #if DEBUG
        // tests only: phonebox://chat-test?text=... types into the chat window and presses Send (the simulator takes no typing)
        if url.scheme == "phonebox", url.host == "chat-test",
           let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value {
            run("(function(){var r=document.getElementById('pbChat');if(!r)return;var t=r.querySelector('textarea');t.value=\(jsQuote(text));r.querySelector('.pc-send').click();})()")
            return
        }
        if url.scheme == "phonebox", url.host == "debug-hosts" {
            let list = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "h" })?.value ?? "")
                .split(separator: ",").map(String.init)
            link.debugSetAddresses(list)
            restart()
            return
        }
        if url.scheme == "phonebox", url.host == "chat-eval",
           let js = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "js" })?.value {
            web.evaluateJavaScript(js) { result, error in NSLog("PhoneBoxEval %@ %@", String(describing: result), String(describing: error)) }
            return
        }
        #endif
        guard let pairing = AgentLink.PairLink.parse(url) else { return }
        confirmPairing(pairing)
    }

    private func presenter() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private func confirmPairing(_ pairing: AgentLink.PairLink) {
        guard !self.pairing else { return }
        let alert = UIAlertController(title: L("pair_title"),
                                      message: L("pair_message", pairing.pc, pairing.hosts.joined(separator: ", "), pairing.port, pairing.check),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("pair_negative"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("pair_positive"), style: .default) { [weak self] _ in self?.pair(pairing) })
        show(alert)
    }

    private func pair(_ pairing: AgentLink.PairLink) {
        self.pairing = true
        Toast.show(L("pair_progress", pairing.pc), long: false, in: view.window)
        Task {
            let problem = await link.claim(pairing)
            self.pairing = false
            if let problem {
                let alert = UIAlertController(title: L("pair_failed_title"), message: problem.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("ok"), style: .default))
                self.show(alert)
            } else {
                Toast.show(L("pair_done", pairing.pc), long: true, in: self.view.window)
                self.restart()
            }
        }
    }

    /// Presents [controller] once no other presentation or dismissal is running (an alert's button handler runs while
    /// its alert is still leaving the screen), and only if [when] still holds by then.
    private func show(_ controller: UIViewController, when: @escaping () -> Bool = { true }) {
        let top = presenter()
        if top.transitionCoordinator != nil || top.presentedViewController?.isBeingDismissed == true || top.isBeingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.show(controller, when: when) }
            return
        }
        if when() { top.present(controller, animated: true) }
    }

    // MARK: web view delegates

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The panel is the only page of the main frame; links inside widget frames stay in their frames.
        if navigationAction.targetFrame?.isMainFrame ?? true, navigationAction.request.url?.scheme != PanelSchemeHandler.scheme,
           navigationAction.request.url?.absoluteString != "about:blank" {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { NSLog("PhoneBox navigation failed: %@", error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { NSLog("PhoneBox navigation failed: %@", error.localizedDescription) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("ok"), style: .default) { _ in completionHandler() })
        show(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("pair_negative"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: L("ok"), style: .default) { _ in completionHandler(true) })
        show(alert)
    }
}

/// WKUserContentController retains its handlers; this keeps the view controller from being retained by it.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Volume buttons flip to the previous / next page (the panel's "Volume keys" setting). iOS has no key events for the
/// volume buttons, so a press is recognised by the system output volume changing, and the volume is put back at once.
@MainActor
final class VolumeKeys: NSObject {
    private let onKey: (String) -> Void
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private var last: Float = 0
    private var restoring = false
    /// The volume before it was moved away from the very top or bottom; put back when the keys are released.
    private var moved: Float?

    init(host: UIView, onKey: @escaping (String) -> Void) {
        self.onKey = onKey
        super.init()
        volumeView.alpha = 0.01
        host.addSubview(volumeView) // an MPVolumeView in the hierarchy also hides the system volume HUD
    }

    private var slider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }

    private func setVolume(_ value: Float) {
        guard let slider else { return }
        restoring = true
        slider.value = value
    }

    func setEnabled(_ on: Bool) {
        observation = nil
        guard on else {
            if let moved { setVolume(moved); restoring = false }
            moved = nil
            return
        }
        last = AVAudioSession.sharedInstance().outputVolume
        // At full or zero volume one of the keys changes nothing, so it could not flip a page: step one notch inwards
        // while the keys flip pages (Android's keys never touch the volume while they do), and step back afterwards.
        if last >= 0.99 || last <= 0.01 {
            moved = last
            last = last >= 0.99 ? 0.9375 : 0.0625
            setVolume(last)
        }
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            Task { @MainActor in self?.changed(to: change.newValue ?? 0) }
        }
    }

    private func changed(to volume: Float) {
        if restoring && abs(volume - last) < 0.001 { restoring = false; return }
        restoring = false
        guard abs(volume - last) >= 0.001 else { return }
        let up = volume > last
        setVolume(last) // the volume stays where it was
        onKey(up ? "prev" : "next")
    }
}

/// Android's Toast: a short message at the bottom of the screen that goes away by itself.
@MainActor
enum Toast {
    static func show(_ text: String, long: Bool, in window: UIWindow?) {
        guard let window else { return }
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.backgroundColor = UIColor(white: 0.2, alpha: 0.95)
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, multiplier: 0.8),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: long ? 3.5 : 2.0, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 18, dy: 10)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 36, height: size.height + 20)
    }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        super.textRect(forBounds: bounds.insetBy(dx: 18, dy: 10), limitedToNumberOfLines: n).insetBy(dx: -18, dy: -10)
    }
}

/// Power standby (display.standby in the panel's settings; `setStandby` of the Android app): a desk panel fed by one
/// computer should stop holding the screen once that computer is gone. "off" (the default) keeps the screen on; "power"
/// watches the charging state; "data" watches whether the agent still answers. Once the computer has been judged absent
/// for the grace period the app stops holding the screen on, so iOS' own auto-lock dims and locks it; the moment the
/// computer is back the hold is taken again. (An app can only stop insisting that the screen stays on.)
@MainActor
final class PowerStandby {
    private let link: AgentLink
    private var mode = "off"
    private var grace: TimeInterval = 30
    private var active = false
    private var lostSince: Date?
    private var absent = false
    private var timer: Timer?
    private static let silence: TimeInterval = 12

    init(link: AgentLink) { self.link = link }

    func configure(mode: String, graceSeconds: Int) {
        let m = ["power", "data"].contains(mode.lowercased()) ? mode.lowercased() : "off"
        let g = TimeInterval(min(max(graceSeconds, 3), 600))
        guard m != self.mode || g != grace else { return }
        self.mode = m
        grace = g
        lostSince = nil
        absent = false
        apply()
        restartTimer()
    }

    func setActive(_ on: Bool) {
        active = on
        restartTimer()
        if !on { UIApplication.shared.isIdleTimerDisabled = false } else { apply() }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard active, mode != "off" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func computerGone() -> Bool {
        switch mode {
        case "power":
            let state = UIDevice.current.batteryState
            return !(state == .charging || state == .full)
        case "data":
            return Date().timeIntervalSince(link.lastAnswer) >= Self.silence
        default:
            return false
        }
    }

    private func tick() {
        guard active else { return }
        if !computerGone() {
            lostSince = nil
            if absent { absent = false; apply() }
            return
        }
        guard let since = lostSince else { lostSince = Date(); return }
        if !absent, Date().timeIntervalSince(since) >= grace { absent = true; apply() }
    }

    private func apply() {
        // the screen is held on while standby is off or the computer is judged present
        UIApplication.shared.isIdleTimerDisabled = active && (mode == "off" || !absent)
    }
}
