// Transcript.swift
// A window that shows one Claude session's transcript, rendered by the
// claude-instances session hub (lib/transcript-app.html, served on :5400).

import AppKit
import WebKit

/// Says in the window when the hub could not be reached, instead of leaving
/// it blank; Retry loads the transcript again.
final class TranscriptNav: NSObject, WKNavigationDelegate, WKUIDelegate {
    let url: URL
    /// The last load error, for the headless probe.
    var lastError: NSError?
    /// Called when the page finished or an error page replaced it, so the "Loading" cover can go.
    var onSettled: () -> Void = {}
    init(url: URL) { self.url = url }

    func webView(_ web: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) { show(web, error) }
    func webView(_ web: WKWebView, didFail _: WKNavigation!, withError error: Error) { show(web, error) }
    func webView(_ web: WKWebView, didFinish _: WKNavigation!) { onSettled() }

    /// The hub can answer, but with a 404 or 500; that is a failure too, and it gets the same Retry.
    func webView(_ web: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            showMessage(web, Self.statusMessage(http.statusCode))
            return
        }
        decisionHandler(.allow)
    }

    /// A crashed web process leaves a blank view; say so and offer Retry.
    func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
        showMessage(web, "The transcript view stopped working. Retry to load it again.")
    }

    static func statusMessage(_ code: Int) -> String {
        code == 404
            ? "The session hub has no transcript for this session (it answered \(code)). The session may be too old or gone."
            : "The session hub answered with an error (\(code)), so the transcript could not load. Retry in a moment."
    }

    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.scheme == "switchboard-retry" {
            decisionHandler(.cancel)
            web.load(URLRequest(url: url))
            return
        }
        if let to = action.request.url, Self.opensInBrowser(to, button: action.buttonNumber,
                                                            command: action.modifierFlags.contains(.command),
                                                            newWindow: action.targetFrame == nil, link: action.navigationType == .linkActivated) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(to)
            return
        }
        decisionHandler(.allow)
    }

    /// A link meant for a new tab (target=_blank, window.open) opens in the browser.
    func webView(_ web: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let to = action.request.url { NSWorkspace.shared.open(to) }
        return nil
    }

    /// The hub's own pages stay in the window; a middle click, a Command-click, a
    /// link asking for a new tab, or a page outside the hub opens in the browser.
    static func opensInBrowser(_ url: URL, button: Int, command: Bool, newWindow: Bool, link: Bool) -> Bool {
        let hub = (url.host == "127.0.0.1" || url.host == "localhost") && url.port == 5400
        if url.scheme == "about" || url.scheme == "data" { return false }
        if !hub { return link || newWindow }
        return button == 2 || command || newWindow
    }

    private func show(_ web: WKWebView, _ error: Error) {
        lastError = error as NSError
        // A load we cancelled ourselves (an error status, a retry) already has its own message.
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        showMessage(web, (error as NSError).code == NSURLErrorCannotConnectToHost
            ? "The session hub on port 5400 is not running. Turn it on from Runtime > Services, then retry."
            : "The transcript could not load: \(error.localizedDescription)")
    }

    private func showMessage(_ web: WKWebView, _ why: String) {
        onSettled()
        let html = """
        <html><body style="font: 14px -apple-system; color: #888; padding: 40px; background: transparent">
        <p>\(why)</p><p><a href="switchboard-retry://again">Retry</a></p></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }
}

/// Loads a transcript from a port nothing listens on and reads back what the
/// window would show. Opens no window.
func probeTranscript() -> String {
    let url = URL(string: "http://127.0.0.1:59998/s/probe")!
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let nav = TranscriptNav(url: url)
    web.navigationDelegate = nav
    web.load(URLRequest(url: url))
    var text = ""
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && !text.contains("Retry") {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        web.evaluateJavaScript("document.body ? document.body.innerText : ''") { v, _ in text = (v as? String) ?? "" }
    }
    let ok = text.contains("not running") && text.contains("Retry")
    let err = nav.lastError.map { "\($0.domain) \($0.code)" } ?? "no load error seen"
    let status = TranscriptNav.statusMessage(500).contains("error (500)") && TranscriptNav.statusMessage(404).contains("no transcript")
    let all = ok && status
    return "\(ok ? "ok  " : "FAIL") a hub that is down says so, with Retry\(ok ? "" : " (got: \(text.prefix(80)); \(err))")\n"
        + "\(status ? "ok  " : "FAIL") a hub error status gets its own sentence\n\(all ? "all passed" : "some failed")"
}

enum TranscriptWindow {
    /// Open windows, one per session, so a second click brings the first back.
    private static var open: [String: NSWindow] = [:]
    /// Web views hold their delegate weakly; these keep them alive with the window.
    private static var navs: [String: TranscriptNav] = [:]

    static func url(for sessionID: String) -> URL? {
        URL(string: "http://127.0.0.1:5400/s/\(sessionID)")
    }

    /// Show the session's transcript, reusing its window if one is open.
    static func show(sessionID: String, title: String) {
        guard let url = url(for: sessionID) else { return }
        show(url: url, key: sessionID, title: title, loading: "Loading the transcript…")
    }

    /// A page the session hub serves, which opens in Switchboard's window by default.
    static func isHub(_ url: URL) -> Bool {
        (url.host == "127.0.0.1" || url.host == "localhost") && url.port == 5400
    }

    /// The hub's board of every session, in its own window rather than the browser.
    static func showBoard() {
        guard let url = URL(string: "http://127.0.0.1:5400/") else { return }
        show(url: url, key: "board", title: "Session hub", loading: "Loading the session hub…")
    }

    /// Any hub page in a window of its own, one window per key.
    static func show(url: URL, key sessionID: String, title: String, loading label: String) {
        if let w = open[sessionID] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let frame = NSRect(x: 0, y: 0, width: 900, height: 760)
        let web = WKWebView(frame: frame)
        web.autoresizingMask = [.width, .height]
        let nav = TranscriptNav(url: url)
        navs[sessionID] = nav
        web.navigationDelegate = nav
        web.uiDelegate = nav
        web.load(URLRequest(url: url))
        // The page is blank until the hub answers; a cover with a label says it is on its way.
        let box = NSView(frame: frame)
        let cover = NSView(frame: frame)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        cover.autoresizingMask = [.width, .height]
        let loading = NSTextField(labelWithString: label)
        loading.textColor = .secondaryLabelColor
        loading.sizeToFit()
        loading.frame.origin = NSPoint(x: (frame.width - loading.frame.width) / 2, y: frame.height / 2)
        loading.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        cover.addSubview(loading)
        box.addSubview(web)
        box.addSubview(cover)
        nav.onSettled = { cover.isHidden = true }
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = box
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("transcript-window")
        open[sessionID] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            open[sessionID] = nil
            navs[sessionID] = nil
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens a link: a session hub page in Switchboard's own window, anything else in the browser.
func openLink(_ url: URL) {
    guard TranscriptWindow.isHub(url) else { NSWorkspace.shared.open(url); return }
    let sid = url.path.hasPrefix("/s/") ? String(url.path.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
    if sid.isEmpty { TranscriptWindow.showBoard() } else { TranscriptWindow.show(sessionID: sid, title: "Transcript") }
}
