// NoteComments.swift
// Comments on a note, the way bfb keeps them for any markdown file: threads in `<note>.md.bfb.json` beside it,
// written only through `bfb-docs`, which locks, merges with other writers and never drops a thread. This file reads
// the companion for display (the contract allows reading) and runs `bfb-docs` for every change, as the owner,
// so a comment made here shows in bfb and the other way round. A comment never changes the note.

import Foundation
import SwiftUI

enum NoteComments {
    struct Comment: Identifiable, Equatable {
        let id: String
        let author: String
        let text: String
        let at: Date?
    }
    struct Thread: Identifiable, Equatable {
        let id: String
        /// The words in the note the thread is about.
        let quote: String
        let open: Bool
        /// `anchored`, `moved` or `detached`, as bfb works out where the words are now (nil when it has not).
        let place: String?
        let comments: [Comment]
    }

    /// Where `bfb-docs` is: the usual install places. A probe sets this to a stand-in.
    static var toolPath: String? = {
        ["~/.local/bin/bfb-docs", "/opt/homebrew/bin/bfb-docs", "/usr/local/bin/bfb-docs"]
            .map { ($0 as NSString).expandingTildeInPath }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    /// Where bfb keeps its state (`BFB_DOCS_HOME`); a probe points it at a scratch folder so nothing lands in the owner's index.
    static var docsHome: String?

    static func companion(of notePath: String) -> String { notePath + ".bfb.json" }

    // ── Reading ─────────────────────────────────────────────────────────────

    private static var cache: [String: (mtime: Date?, threads: [Thread])] = [:]
    private static let lock = NSLock()

    /// Every thread of a note, read from its companion file; empty when it has none. Re-read only when the file changed.
    static func threads(of notePath: String) -> [Thread] {
        let p = companion(of: notePath)
        let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        guard m != nil else { return [] }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[p], c.mtime == m { return c.threads }
        let list = parse(FileManager.default.contents(atPath: p) ?? Data())
        cache[p] = (m, list)
        return list
    }

    static func parse(_ data: Data) -> [Thread] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = o["comments"] as? [String: Any], let ts = c["threads"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ts.compactMap { t -> Thread? in
            guard let id = t["id"] as? String else { return nil }
            let cs = (t["comments"] as? [[String: Any]] ?? []).compactMap { c -> Comment? in
                guard let cid = c["id"] as? String, let text = c["text"] as? String else { return nil }
                let a = c["author"] as? [String: Any]
                let who = (a?["name"] as? String) ?? (a?["alias"] as? String) ?? (a?["kind"] as? String) ?? "someone"
                return Comment(id: cid, author: who, text: text, at: (c["created"] as? String).flatMap(iso.date))
            }
            return Thread(id: id, quote: (t["anchor"] as? [String: Any])?["exact"] as? String ?? "", open: (t["status"] as? String ?? "open") != "done",
                          place: (t["place"] as? [String: Any])?["state"] as? String, comments: cs)
        }
    }

    /// How many threads are waiting on someone.
    static func openCount(of notePath: String) -> Int { threads(of: notePath).filter(\.open).count }

    // ── Changing, through bfb-docs ──────────────────────────────────────────

    struct Run { let code: Int32; let out: String; let err: String }

    static func run(_ args: [String], timeout: TimeInterval = 10) -> Run {
        guard let tool = toolPath else { return Run(code: 127, out: "", err: "bfb-docs is not installed, so comments cannot be changed here.") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = ["--as", "user"] + args
        var env = ProcessInfo.processInfo.environment
        if let h = docsHome { env["BFB_DOCS_HOME"] = h }
        p.environment = env
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return Run(code: 127, out: "", err: "bfb-docs could not be started: \(error.localizedDescription)") }
        var out = Data(), err = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { out = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { err = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return Run(code: 124, out: "", err: "bfb-docs did not answer in \(Int(timeout)) s.") }
        g.wait()
        return Run(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }

    /// The failure in a sentence, or nil.
    private static func said(_ r: Run) -> String? {
        guard r.code != 0 else { return nil }
        let t = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "bfb-docs failed (exit \(r.code))." : t.components(separatedBy: "\n").last ?? t
    }

    /// A new thread about `quote`, which must be words that are in the note's file exactly.
    static func add(to notePath: String, quote: String, text: String) -> String? {
        said(run(["comments", "new", notePath, "--quote", quote, text]))
    }
    static func reply(in notePath: String, thread: String, text: String) -> String? {
        said(run(["comments", "reply", notePath, thread, text]))
    }
    static func done(in notePath: String, thread: String, text: String) -> String? {
        said(run(["comments", "done", notePath, thread, text]))
    }

    /// Words from the note to hang a comment on: the first line of its body, else its title, cut at 60 characters
    /// and at a word. They must also be in the file as written, so a title with an escape in it is not offered.
    static func defaultQuote(_ n: Note) -> String {
        let first = n.body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? n.title
        guard first.count > 60, let cut = first.prefix(60).lastIndex(of: " ") else { return String(first.prefix(60)) }
        return String(first[..<cut])
    }
}

/// The bubble on a closed row: how many threads wait.
struct CommentsBadge: View {
    let path: String
    var body: some View {
        let n = NoteComments.openCount(of: path)
        if n > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.fill").font(.sbIcon(8.5))
                Text("\(n)").font(.sb(10, weight: .medium))
            }
            .foregroundStyle(Color.accentColor).fixedSize().layoutPriority(1)
            .help("\(n) open comment thread\(n == 1 ? "" : "s"); open the note to read them")
        }
    }
}

/// The comments of one open note: the open threads with their replies, a reply box and Done on each, and a box to
/// start a new thread on words from the note.
struct CommentsPanel: View {
    let note: Note
    @State private var threads: [NoteComments.Thread] = []
    @State private var reply: [String: String] = [:]
    @State private var quote = ""
    @State private var text = ""
    @State private var problem: String?
    @State private var busy = false

    private var path: String { note.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let open = threads.filter(\.open), done = threads.count - open.count
            if open.isEmpty { Text("No open comments.").font(PT.caption).foregroundStyle(.secondary) }
            ForEach(open) { t in thread(t) }
            if done > 0 { Text("\(done) closed").font(PT.caption).foregroundStyle(.tertiary) }
            Divider()
            Text("New comment about").font(PT.caption).foregroundStyle(.secondary)
            TextField("words from the note", text: $quote).textFieldStyle(.plain).font(PT.caption).inputBox(focused: false)
            TextField("Comment", text: $text, axis: .vertical).textFieldStyle(.plain).font(PT.label).lineLimit(1...5).inputBox(focused: false)
                .onSubmit { addThread() }
            HStack {
                if let p = problem { Text(p).font(PT.caption).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("Comment") { addThread() }.disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty || quote.isEmpty)
            }
        }
        .padding(10).frame(width: 300)
        .onAppear { quote = NoteComments.defaultQuote(note); reload() }
    }

    private func thread(_ t: NoteComments.Thread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\u{201C}" + t.quote + "\u{201D}").font(.sb(10.5).italic()).lineLimit(2).foregroundStyle(.secondary)
                if let p = t.place, p != "anchored" { KeyPill(text: p) }
            }
            ForEach(t.comments) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.author).font(.sb(10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(c.text).font(PT.label).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                TextField("Reply", text: Binding(get: { reply[t.id] ?? "" }, set: { reply[t.id] = $0 })).textFieldStyle(.plain).font(PT.caption)
                    .inputBox(focused: false).onSubmit { send(t) }
                Button("Reply") { send(t) }.disabled((reply[t.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Done") { close(t) }.disabled(busy).help("Close this thread")
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func reload() { threads = NoteComments.threads(of: path) }

    private func act(_ f: @escaping () -> String?) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let why = f()
            DispatchQueue.main.async { busy = false; problem = why; reload() }
        }
    }
    private func addThread() {
        let q = quote, t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !t.isEmpty else { return }
        act { let r = NoteComments.add(to: path, quote: q, text: t); if r == nil { DispatchQueue.main.async { text = "" } }; return r }
    }
    private func send(_ t: NoteComments.Thread) {
        let r = (reply[t.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        act { let e = NoteComments.reply(in: path, thread: t.id, text: r); if e == nil { DispatchQueue.main.async { reply[t.id] = "" } }; return e }
    }
    private func close(_ t: NoteComments.Thread) { act { NoteComments.done(in: path, thread: t.id, text: "Done.") } }
}
