// PiLink.swift
// Puts a note's words on the Raspberry Pi's screen. The Pi may be off or out
// of reach; that is reported in plain words and never treated as a failure of
// the app. The mesh token is read from the owner's csync config, never stored.

import Foundation

enum PiLink {
    /// A probe points these at a stand-in; the app leaves them nil.
    static var baseOverride: String?
    static var tokenOverride: String?

    static let defaultHost = "100.65.188.9"
    static let port = 8792
    static var tokenPath: String { NSHomeDirectory() + "/.config/csync/mesh.token" }

    /// The Pi's host: the one the notes remote syncs with, else the known Tailscale address.
    static func host(remote: String) -> String {
        guard let at = remote.firstIndex(of: "@") else { return defaultHost }
        let rest = remote[remote.index(after: at)...]
        let h = rest.prefix { $0 != ":" && $0 != "/" }
        return h.isEmpty ? defaultHost : String(h)
    }

    static func base(remote: String) -> String { baseOverride ?? "http://\(host(remote: remote)):\(port)" }

    static func token() -> String? {
        if let t = tokenOverride { return t }
        let t = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    /// The words sent: at most 4000 characters, cut after a whole word, as the Pi expects.
    static func screenText(_ s: String) -> String {
        guard s.count > 4000 else { return s }
        let head = String(s.prefix(4000))
        if let cut = head.lastIndex(where: { $0.isWhitespace }) { return String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return head
    }

    /// The request that shows a note, or nil when there is nothing to show.
    static func request(title: String, body: String, base: String, token: String) -> URLRequest? {
        let words = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = words.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : screenText(words)
        guard !text.isEmpty, let url = URL(string: base + "/v1/display/show"),
              let data = try? JSONSerialization.data(withJSONObject: ["title": title, "text": text]) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(token, forHTTPHeaderField: "X-Csync-Token")
        r.httpBody = data
        return r
    }

    /// Shows the note on the Pi screen; `done` hears a sentence for the owner, on the main thread.
    static func show(_ note: Note, remote: String, done: @escaping (_ ok: Bool, _ message: String) -> Void) {
        guard let token = token() else {
            done(false, "The Pi was not reached: there is no mesh token at ~/.config/csync/mesh.token."); return
        }
        guard let req = request(title: note.title, body: note.body, base: base(remote: remote), token: token) else {
            done(false, "This note has no words to show."); return
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let message: (Bool, String)
            if let err = err { dlog("show on Pi failed: \(err)") }
            if let err = err as? URLError, [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost].contains(err.code) {
                message = (false, "The Pi did not answer. Is it on and on Tailscale? Nothing was changed.")
            } else if let err = err {
                message = (false, "The Pi was not reached: \(err.localizedDescription)")
            } else if let code = (resp as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 {
                message = (false, "The Pi did not accept the mesh token.")
            } else if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                message = (false, "The Pi said no (\(code)).")
            } else {
                let lit = ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any])?["sentToDisplay"] as? Bool ?? true
                message = (true, lit ? "Showing on the Pi screen." : "Sent. The Pi screen is off.")
            }
            DispatchQueue.main.async { done(message.0, message.1) }
        }.resume()
    }
}
