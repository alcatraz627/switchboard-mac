// Transcript.swift
// A window that shows one Claude session's transcript, rendered by the
// claude-instances session hub (lib/transcript-app.html, served on :5400).

import AppKit
import WebKit

enum TranscriptWindow {
    /// Open windows, one per session, so a second click brings the first back.
    private static var open: [String: NSWindow] = [:]

    static func url(for sessionID: String) -> URL? {
        URL(string: "http://127.0.0.1:5400/s/\(sessionID)")
    }

    /// Show the session's transcript, reusing its window if one is open.
    static func show(sessionID: String, title: String) {
        if let w = open[sessionID] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let url = url(for: sessionID) else { return }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("transcript-window")
        open[sessionID] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            open[sessionID] = nil
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
