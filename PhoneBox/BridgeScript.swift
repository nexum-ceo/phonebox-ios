import Foundation

/// The JavaScript that gives the panel the same `Android` object it has in the Android app, so the bundled panel
/// (www/) runs unchanged. It is injected at document start into the main frame only: sandboxed widget frames never get
/// the object (and, as in the Android app, every call also carries a key that only the panel's frame knows).
///
/// WKWebView cannot answer a synchronous call from the page (a synchronous XHR to a custom scheme hangs the page), but
/// the panel reads a few values synchronously (battery, transport, the paired computers...). Those come from a state
/// object the app writes into the page at load and then whenever it changes (window.__pbSet). Calls that only act are
/// posted to the native side.
enum BridgeScript {
    /// Calls that return a value, read from the state: name -> state key.
    static let readers: [String: String] = [
        "battery": "battery", "transport": "transport", "sensors": "sensors", "version": "version",
        "is24Hour": "is24Hour", "pcs": "pcs", "canWake": "canWake", "canListen": "canListen",
    ]
    static let acting: [String] = ["trackpad", "setLanguage", "setBrightness", "haptic", "buzz", "setVolumeKeys", "setPinned", "selectPc",
                                    "forgetPc", "setOrientation", "setHomeScreen", "stopListening", "cancelListening", "log",
                                    "chatOpen", "chatSend", "chatCancel", "chatNew", "chatFolder", "chatRotate", "setStandby"] // the last five: the iOS Claude Code chat

    static func source(key: String, languages: [String], state: String) -> String {
        """
        (function () {
          window.__phoneboxKey = \(jsQuote(key));
          window.__phoneboxLanguages = \(jsonString(languages));
          var state = \(state);
          var readers = \(jsonString(readers)), acting = \(jsonString(acting));
          var native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.phonebox;
          var listenId = 0;
          var Android = {};
          function post(name, args) { if (native) native.postMessage({ method: name, args: Array.prototype.slice.call(args) }); }
          Object.keys(readers).forEach(function (name) {
            Android[name] = function () { return state[readers[name]]; };
          });
          acting.forEach(function (name) { Android[name] = function () { post(name, arguments); }; });
          // the id of a dictation session is made here, so the call can return it at once
          Android.listen = function (key, lang, offline) {
            var id = ++listenId;
            post('listen', [key, lang, offline, id]);
            return id;
          };
          // whether the packet can be sent is known from the state; sending it takes a moment
          Android.wakePc = function (key, id) { post('wakePc', [key, id]); return !!state.canWake; };
          Object.defineProperty(window, '__pbSet', { value: function (next) { state = next; }, writable: false, configurable: false });
          // errors of the panel go to the app's log (Xcode console / Console.app), as logcat shows them on Android
          function report(text) { try { post('log', [window.__phoneboxKey, String(text).slice(0, 2000)]); } catch (e) {} }
          window.addEventListener('error', function (e) { report('error: ' + (e.message || (e.target && ('failed to load ' + (e.target.src || e.target.href)))) + ' @' + e.filename + ':' + e.lineno); }, true);
          window.addEventListener('unhandledrejection', function (e) { report('unhandled: ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason)); });
          ['error', 'warn'].forEach(function (level) {
            var original = console[level];
            console[level] = function () { report(level + ': ' + Array.prototype.slice.call(arguments).join(' ')); original.apply(console, arguments); };
          });
          Object.defineProperty(window, 'Android', { value: Android, writable: false, configurable: false });
        })();
        """
    }
}
