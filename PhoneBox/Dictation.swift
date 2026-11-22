import AVFoundation
import Speech
import UIKit

/// Speech to text for the Dictation widget, with the phone's own speech recognizer (Apple's Speech framework; the
/// counterpart of Dictation.kt). "On the phone only" uses on-device recognition, which never leaves the phone, and is
/// refused with an error when the language has no on-device model.
///
/// One session at a time, at most `maxSeconds` long, cancelled when the panel pauses. Every session has an id: events go
/// to the panel's main frame as window.onAndroidSpeech(kind, text, id), and stop or cancel act only on the session they
/// name. Nothing is stored. Every entry point runs on the main thread.
@MainActor
final class Dictation {
    private let js: (String) -> Void
    private var session = 0
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var timeLimit: Task<Void, Never>?

    private static let maxSeconds: UInt64 = 60
    private static let maxChars = 2000

    init(js: @escaping (String) -> Void) { self.js = js }

    func available() -> Bool { SFSpeechRecognizer()?.isAvailable ?? false }

    /// Starts session [id] (made by the page); asks for speech recognition and the microphone first if needed.
    func start(id: Int, lang: String, offline: Bool) {
        let locale = lang.isEmpty ? Locale.current : Locale(identifier: lang)
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.send("error", status == .notDetermined ? "permission" : "permission-blocked", id); return }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        if granted { self.begin(id: id, locale: locale, offline: offline) }
                        else { self.send("error", "permission-blocked", id) }
                    }
                }
            }
        }
    }

    /// Stops listening and delivers what was heard so far, if [id] is the session running.
    func stop(_ id: Int) {
        guard id == session else { return }
        finishAudio()
    }

    /// Drops the session without a result, if [id] is the one running. 0 = whatever runs (the panel paused).
    func cancel(_ id: Int) {
        guard recognizer != nil, id == 0 || id == session else { return }
        let was = session
        end()
        send("error", "cancelled", was)
    }

    private func begin(id: Int, locale: Locale, offline: Bool) {
        if recognizer != nil { let was = session; end(); send("error", "cancelled", was) }
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), r.isAvailable else { send("error", "unavailable", id); return }
        if offline && !r.supportsOnDeviceRecognition { send("error", "offline-unavailable", id); return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try audio.setActive(true)
        } catch { send("error", "unavailable", id); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if offline { req.requiresOnDeviceRecognition = true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { send("error", "unavailable", id); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); send("error", "unavailable", id); return }
        recognizer = r
        request = req
        self.engine = engine
        session = id
        task = r.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal { self.end(); self.send("final", text, id) } else { self.send("partial", text, id) }
                } else if let error = error as NSError? {
                    self.end()
                    // 1110 = no speech detected, 216 / 203 = nothing recognized; anything else is a service problem
                    let noMatch = [1110, 216, 203, 301].contains(error.code)
                    self.send("error", noMatch ? "7" : "2", id)
                }
            }
        }
        send("ready", "", id)
        timeLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxSeconds * 1_000_000_000)
            if !Task.isCancelled { self?.finishAudio() }
        }
    }

    /// No more audio: the recognizer delivers the final result.
    private func finishAudio() {
        guard let request else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request.endAudio()
        send("end", "", session)
    }

    private func end() {
        timeLimit?.cancel()
        timeLimit = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine, engine.isRunning { engine.stop() }
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        recognizer = nil
        session = 0
        // back to the category the panel plays its sound with
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? audio.setActive(true)
    }

    private func send(_ kind: String, _ text: String, _ id: Int) {
        js("window.onAndroidSpeech && window.onAndroidSpeech(\(jsQuote(kind)), \(jsQuote(String(text.prefix(Self.maxChars)))), \(id))")
    }
}
