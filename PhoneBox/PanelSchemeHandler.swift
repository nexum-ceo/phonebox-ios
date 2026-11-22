import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the panel (the bundled www folder) and forwards "/agent/..." requests to the PhoneBox agent, exactly like the
/// Android app's WebViewAssetLoader and shouldInterceptRequest. The panel lives at phonebox-app://appassets.androidplatform.net/
/// (the host name the panel's own code already knows), and its WebView never makes a local-network request itself.
///
/// Only the panel itself may reach the agent: every frame comes through here, including the sandboxed iframe of a Custom
/// HTML widget. The panel sends X-PhoneBox-Panel on its requests; a sandboxed frame cannot add it without a CORS
/// preflight, which is refused. Images (album art, process icons) cannot carry headers, but they are read-only GETs.
@MainActor
final class PanelSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "phonebox-app"
    static let host = "appassets.androidplatform.net"
    static let startURL = URL(string: "\(scheme)://\(host)/assets/www/index.html")!

    private static let panelHeader = "X-PhoneBox-Panel"
    private static let readOnlyImages: Set<String> = [
        "/agent/api/art", "/agent/api/procs/icon", "/agent/api/controls/radio-logo", "/agent/api/apps/icon",
        "/agent/api/discord/img", "/agent/api/shortcuts/icon", "/agent/api/steam/cover",
    ]

    let link: AgentLink
    /// The tasks WebKit has started and not cancelled. Holding the task object keeps its address from being reused by a new
    /// task while an answer for it is still on its way.
    private var active: [ObjectIdentifier: WKURLSchemeTask] = [:]

    init(link: AgentLink) { self.link = link }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        active[ObjectIdentifier(task)] = task
        let request = task.request
        guard let url = request.url else { fail(task); return }
        let path = url.path
        if path.hasPrefix("/agent/") {
            if fromPanel(request) { proxy(task) } else { respond(task, status: 403, mime: "text/plain", body: Data()) }
            return
        }
        serveAsset(task, path: path)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active[ObjectIdentifier(task)] = nil
    }

    private func live(_ task: WKURLSchemeTask) -> Bool { active[ObjectIdentifier(task)] === task }

    private func fail(_ task: WKURLSchemeTask) {
        if live(task) { task.didFailWithError(URLError(.badURL)) }
        active[ObjectIdentifier(task)] = nil
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, mime: String, charset: String? = nil, body: Data) {
        guard live(task), let url = task.request.url else { return }
        if status >= 400 && status != 503 { NSLog("PhoneBox %d %@", status, url.path) }
        var headers = ["Content-Type": charset.map { "\(mime); charset=\($0)" } ?? mime,
                       "Content-Length": String(body.count), "Cache-Control": "no-store"]
        if url.path.hasPrefix("/assets/") { headers["Access-Control-Allow-Origin"] = "*" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
        active[ObjectIdentifier(task)] = nil
    }

    // MARK: assets

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "json": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "mp3": "audio/mpeg",
        "wav": "audio/wav", "ogg": "audio/ogg", "txt": "text/plain", "map": "application/json", "wasm": "application/wasm",
    ]

    private func serveAsset(_ task: WKURLSchemeTask, path: String) {
        // /assets/www/... -> <bundle>/www/...
        guard path.hasPrefix("/assets/"), let root = Bundle.main.resourceURL?.standardizedFileURL else {
            respond(task, status: 404, mime: "text/plain", body: Data()); return
        }
        let file = root.appendingPathComponent(String(path.dropFirst("/assets/".count))).standardizedFileURL
        // never leave the bundled www folder
        guard file.path.hasPrefix(root.appendingPathComponent("www").path + "/"), let data = try? Data(contentsOf: file) else {
            respond(task, status: 404, mime: "text/plain", body: Data()); return
        }
        let ext = file.pathExtension.lowercased()
        let mime = Self.mimeTypes[ext] ?? "application/octet-stream"
        respond(task, status: 200, mime: mime, charset: mime.hasPrefix("text/") || mime == "application/json" ? "utf-8" : nil, body: data)
    }

    // MARK: agent proxy

    private func fromPanel(_ request: URLRequest) -> Bool {
        let hasHeader = request.allHTTPHeaderFields?.keys.contains { $0.caseInsensitiveCompare(Self.panelHeader) == .orderedSame } ?? false
        return hasHeader || (request.httpMethod == "GET" && Self.readOnlyImages.contains(request.url?.path ?? ""))
    }

    private func proxy(_ task: WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { fail(task); return }
        let path = String(comps.percentEncodedPath.dropFirst("/agent".count))
        let query = comps.percentEncodedQuery.map { "?\($0)" } ?? ""
        let method = request.httpMethod ?? "GET"
        let body = Self.body(of: request)
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        let link = self.link
        Task {
            let reply = await link.request(method: method, pathAndQuery: path + query, body: body, contentType: contentType)
            await MainActor.run {
                guard self.live(task) else { return }
                let ct = reply.contentType ?? "application/octet-stream"
                let mime = ct.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ct
                var charset: String?
                if let range = ct.range(of: "charset=") { charset = String(ct[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
                let status = (100...599).contains(reply.code) && !(300...399).contains(reply.code) ? reply.code : 502
                self.respond(task, status: status, mime: mime, charset: charset, body: reply.body)
            }
        }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.count > 1_000_000 { break }
        }
        return data
    }
}
