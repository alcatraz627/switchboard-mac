// Sessions.swift
// The Sessions hover page: every Claude Code session open on this Mac at a
// glance, grouped by who has the next move (you, Claude, or nobody), with the
// one that has waited longest on top. Rows open the transcript in the hub and
// carry three small actions: focus the terminal, copy the path, copy the ipc id.
//
// The list comes from claude-instances' scanner run here directly, not from the
// hub, so it keeps working when the hub is down. The fields it reads are the
// contract in claude-instances/docs/contract.md, checked by --probe-sessions.

import AppKit
import SwiftUI

/// Who has the next move in a session. The scanner decides; every surface uses its word.
enum Attention: String {
    case needsYou = "needs_you", working, idle

    var color: Color {
        switch self {
        case .needsYou: return Color(nsColor: menuYellow)
        case .working: return Color(nsColor: menuGreen)
        case .idle: return .secondary
        }
    }
}

/// One open Claude Code session, as the card shows it.
struct LiveSession: Identifiable, Equatable {
    let id: String
    let pid: Int
    let name: String
    let cwd: String
    let cwdShort: String
    let attention: Attention
    /// When the session last changed between working and waiting.
    let since: Date?
    /// What it is doing now, in a word or two ("Bash", "Thinking").
    let doing: String
    /// The closing paragraph of Claude's last reply.
    let lastReply: String
    let lastPrompt: String
    let model: String
    var branch: String
    let ctxLeft: Int?
    let costUSD: Double?
    let tokens: Int
    let memoryMB: Int?
    let focusFile: String
    let ipcAlias: String

    var title: String { name.isEmpty ? (cwd as NSString).lastPathComponent : name }
}

/// Reads the scanner's output and puts sessions in the order the card shows them.
enum SessionScan {
    /// Every field the card reads from a live row: the contract with claude-instances.
    static let usedFields = ["session_id", "pid", "name", "cwd", "cwd_short", "attention", "status_since",
                             "session_state", "last_reply", "last_prompt", "model", "git_branch",
                             "cost_usd", "input_tokens", "output_tokens", "statusline", "ipc"]
    static let usedStatuslineFields = ["ctx_remaining", "rss_mb", "focus_file"]

    /// The used fields a scan's live rows lack, so a renamed field fails loudly instead of rendering blank.
    static func missingFields(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["(not JSON)"] }
        guard let live = root["live"] as? [[String: Any]] else { return ["live"] }
        var missing = Set<String>()
        for row in live {
            for f in usedFields where row.index(forKey: f) == nil { missing.insert(f) }
            if let sl = row["statusline"] as? [String: Any] {
                for f in usedStatuslineFields where sl.index(forKey: f) == nil { missing.insert("statusline." + f) }
            }
        }
        return missing.sorted()
    }

    static func parse(_ data: Data) -> [LiveSession]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let live = root["live"] as? [[String: Any]] else { return nil }
        return live.compactMap(session)
    }

    private static func session(_ r: [String: Any]) -> LiveSession? {
        guard let sid = r["session_id"] as? String, !sid.isEmpty else { return nil }
        let sl = r["statusline"] as? [String: Any] ?? [:]
        let st = r["session_state"] as? [String: Any] ?? [:]
        let ipc = r["ipc"] as? [String: Any]
        func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } ?? (v as? Double).map { Int($0) } }
        return LiveSession(
            id: sid, pid: int(r["pid"]) ?? 0, name: str(r, "name"), cwd: str(r, "cwd"), cwdShort: str(r, "cwd_short"),
            attention: Attention(rawValue: str(r, "attention")) ?? .working,
            since: ISO8601DateFormatter().date(from: str(r, "status_since")),
            doing: doingWord(state: str(st, "state"), detail: str(st, "detail")),
            lastReply: str(r, "last_reply"), lastPrompt: str(r, "last_prompt"),
            model: str(r, "model"), branch: str(r, "git_branch"),
            ctxLeft: int(sl["ctx_remaining"]), costUSD: r["cost_usd"] as? Double,
            tokens: (int(r["input_tokens"]) ?? 0) + (int(r["output_tokens"]) ?? 0),
            memoryMB: int(sl["rss_mb"]), focusFile: str(sl, "focus_file"),
            ipcAlias: ipc.map { str($0, "alias") } ?? "")
    }

    /// "Bash: git status" reads as "Bash"; the tail guesses read as verbs.
    static func doingWord(state: String, detail: String) -> String {
        switch state {
        case "tool_use": return detail.split(separator: ":").first.map(String.init) ?? "Tool"
        case "thinking": return "Thinking"
        case "responding": return "Writing"
        default: return "Working"
        }
    }

    /// Needs you first, longest wait on top; then working, longest running first; then idle, most recent first.
    static func ordered(_ s: [LiveSession]) -> [LiveSession] {
        let rank: [Attention: Int] = [.needsYou: 0, .working: 1, .idle: 2]
        return s.sorted { a, b in
            if a.attention != b.attention { return rank[a.attention]! < rank[b.attention]! }
            let ta = a.since ?? .distantFuture, tb = b.since ?? .distantFuture
            if ta != tb { return a.attention == .idle ? ta > tb : ta < tb }
            return a.title < b.title
        }
    }

    /// The session the hero card shows: the one that has waited on you longest, if any.
    static func hero(_ ordered: [LiveSession]) -> LiveSession? { ordered.first { $0.attention == .needsYou } }

    /// A short age: "now", "20m", "3h", "2d".
    static func age(since d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Keeps the session list fresh: every 3 s while the card shows it, every 15 s
/// otherwise so the menu-bar count stays true. A scan costs about a third of a second.
final class SessionsStore: ObservableObject {
    static let shared = SessionsStore()
    @Published private(set) var sessions: [LiveSession] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var failure: String?
    @Published private(set) var loaded = false
    /// The card is open on the Sessions page.
    var watching = false { didSet { if watching && !oldValue { refresh() } } }
    private var timer: Timer?
    private var busy = false
    /// The quick scan leaves the branch out; the last branch seen is kept until a full scan says otherwise.
    private var branches: [String: String] = [:]
    private var lastFull = Date.distantPast

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.watching || (self.lastScan?.timeIntervalSinceNow ?? -.infinity) < -15 { self.refresh() }
        }
        timer?.tolerance = 1
    }

    func refresh() {
        guard !busy else { return }
        guard let script = Integrations.scanScript else {
            failure = "The session scanner (claude-instances) is not installed"; loaded = true; return
        }
        busy = true
        let full = watching && Date().timeIntervalSince(lastFull) > 60
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = Services.run("/bin/bash", full ? [script] : [script, "--quick"], timeout: full ? 15 : 8)
            let parsed = r.ok ? SessionScan.parse(Data(r.out.utf8)) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.loaded = true
                guard var list = parsed else {
                    self.failure = r.ok ? "The session scanner gave output this card cannot read" : (r.failure ?? "The session scanner failed")
                    return
                }
                if full { self.lastFull = Date() }
                for i in list.indices {
                    if !list[i].branch.isEmpty { self.branches[list[i].id] = list[i].branch }
                    else if let b = self.branches[list[i].id] { list[i].branch = b }
                }
                self.failure = nil
                self.lastScan = Date()
                let ordered = SessionScan.ordered(list)
                if ordered != self.sessions { self.sessions = ordered }
            }
        }
    }

    /// Fills the list from scan output already in hand, for snapshots.
    func show(_ data: Data) {
        loaded = true
        guard let list = SessionScan.parse(data) else { failure = "The session scanner gave output this card cannot read"; return }
        lastScan = Date()
        sessions = SessionScan.ordered(list)
    }

    var counts: (needsYou: Int, working: Int, idle: Int) {
        (sessions.filter { $0.attention == .needsYou }.count,
         sessions.filter { $0.attention == .working }.count,
         sessions.filter { $0.attention == .idle }.count)
    }
}

/// The three things a session row can do besides open its transcript.
enum SessionActions {
    /// Brings the session's Ghostty tab forward: the tab in exactly its folder,
    /// else one whose folder ends the same way, else just Ghostty.
    static func focusTerminal(_ s: LiveSession) {
        let full = s.cwd.replacingOccurrences(of: "\"", with: "\\\"")
        let leaf = (s.cwd as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            activate
            try
                set hits to every terminal whose working directory is "\(full)"
                if (count of hits) is 0 then set hits to every terminal whose working directory ends with "/\(leaf)"
                if (count of hits) > 0 then focus item 1 of hits
            end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err { dlog("focus terminal failed: \(err[NSAppleScript.errorMessage] ?? err)") }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens the transcript in its own window, starting the hub first when it is off.
    static func openTranscript(_ s: LiveSession, done: @escaping (String?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let err = Integrations.startHubIfDown() { DispatchQueue.main.async { done(err) }; return }
            DispatchQueue.main.async { TranscriptWindow.show(sessionID: s.id, title: s.title); done(nil) }
        }
    }

    /// Opens the hub's board in Switchboard's own window, or in the browser
    /// (`inBrowser`, a middle click), starting the hub first when it is off.
    static func openHub(inBrowser: Bool = false, done: @escaping (String?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let err = Integrations.startHubIfDown() { DispatchQueue.main.async { done(err) }; return }
            DispatchQueue.main.async {
                if inBrowser { if let u = URL(string: "http://127.0.0.1:5400/") { NSWorkspace.shared.open(u) } }
                else { TranscriptWindow.showBoard() }
                done(nil)
            }
        }
    }

    /// A session's transcript in the browser, for a middle click on its row.
    static func openTranscriptInBrowser(_ s: LiveSession, done: @escaping (String?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let err = Integrations.startHubIfDown() { DispatchQueue.main.async { done(err) }; return }
            DispatchQueue.main.async {
                if let u = TranscriptWindow.url(for: s.id) { NSWorkspace.shared.open(u) }
                done(nil)
            }
        }
    }
}

// ── The page ────────────────────────────────────────────────────────────────

/// The Sessions page of the hover card: a status strip, the session that has
/// waited longest, every other session on one line, and a way to the hub.
struct SessionsPage: View {
    @ObservedObject var store: SessionsStore
    var now: Date = Date()
    @Environment(\.cardSpace) private var cardSpace
    @State private var opening: String?
    @State private var failed: String?

    var body: some View {
        let list = store.sessions
        let hero = SessionScan.hero(list)
        let rest = list.filter { $0.id != hero?.id }
        VStack(alignment: .leading, spacing: 8) {
            if !store.loaded {
                ReadingStatus(state: .loading)
            } else if let f = store.failure, list.isEmpty {
                Text(f).font(.sb(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { store.refresh() }.sbControlSize(.small)
            } else if list.isEmpty {
                Text("No Claude sessions are open").font(.sb(11.5)).foregroundStyle(.secondary)
            } else {
                strip(list)
                if let h = hero {
                    HeroCard(session: h, now: now) { open(h) }
                        .onMiddleClick("shero-" + h.id, space: cardSpace) { openInBrowser(h) }
                }
                ForEach([Attention.needsYou, .working, .idle], id: \.self) { a in
                    let group = rest.filter { $0.attention == a }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(groupTitle(a)).font(.sb(10, weight: .semibold)).foregroundStyle(.tertiary)
                            ForEach(group) { s in
                                SessionRow(session: s, now: now, busy: opening == s.id) { open(s) }
                                    .onMiddleClick("srow-" + s.id, space: cardSpace) { openInBrowser(s) }
                            }
                        }
                    }
                }
            }
            if let f = failed {
                Text(f).font(.sb(10.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.horizontal, -12)
            HStack {
                Button {
                    failed = nil
                    SessionActions.openHub { failed = $0 }
                } label: { Label("Hub", systemImage: "rectangle.grid.2x2") }
                    .buttonStyle(.borderless).font(.sb(11.5))
                    .help("Open the session hub's board: every session, past ones too, with search. Middle-click to open it in the browser.")
                    .onMiddleClick("shub", space: cardSpace) { failed = nil; SessionActions.openHub(inBrowser: true) { failed = $0 } }
                Spacer()
            }
        }
        // the hover card reads every 3 s while open; a desk panel stays up, so it keeps the calmer 15 s pace
        .onAppear { if cardSpace == ScrollTargets.cardSpace { store.watching = true } }
        .onDisappear { if cardSpace == ScrollTargets.cardSpace { store.watching = false } }
    }

    private func groupTitle(_ a: Attention) -> String {
        switch a { case .needsYou: return "Needs you"; case .working: return "Working"; case .idle: return "Idle" }
    }

    private func openInBrowser(_ s: LiveSession) {
        failed = nil
        SessionActions.openTranscriptInBrowser(s) { failed = $0 }
    }

    private func open(_ s: LiveSession) {
        opening = s.id; failed = nil
        SessionActions.openTranscript(s) { err in opening = nil; failed = err }
    }

    /// "2 need you · 3 working · 2 idle · $41 spent", then the scan's age in light grey.
    private func strip(_ list: [LiveSession]) -> some View {
        let c = store.counts
        let spend = list.compactMap(\.costUSD).reduce(0, +)
        var parts: [(String, Color)] = []
        if c.needsYou > 0 { parts.append(("\(c.needsYou) need\(c.needsYou == 1 ? "s" : "") you", Attention.needsYou.color)) }
        if c.working > 0 { parts.append(("\(c.working) working", Attention.working.color)) }
        if c.idle > 0 { parts.append(("\(c.idle) idle", .secondary)) }
        parts.append((String(format: "$%.0f spent", spend), .primary))
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { Text(" · ").foregroundStyle(.tertiary) }
                Text(p.0).foregroundStyle(p.1)
            }
            Spacer(minLength: 6)
            if let t = store.lastScan {
                Text(SessionScan.age(since: t, now: now) == "now" ? "\(max(0, Int(now.timeIntervalSince(t))))s ago" : SessionScan.age(since: t, now: now) + " ago")
                    .foregroundStyle(.quaternary)
                    .help("When the list was last read")
            }
        }
        .font(.sb(11, weight: .medium))
        .help("What the open sessions have cost so far: $\(String(format: "%.2f", spend))")
    }
}

/// The three icon buttons every session carries.
struct SessionIcons: View {
    let session: LiveSession
    @State private var copied: String?

    var body: some View {
        HStack(spacing: 6) {
            icon("terminal", "Bring its terminal to the front") { SessionActions.focusTerminal(session) }
            icon("folder", "Copy its folder: \(session.cwd)") { SessionActions.copy(session.cwd) }
            icon("at", session.ipcAlias.isEmpty ? "No ipc id: the session is not registered with claude-ipc"
                                                 : "Copy its ipc id: \(session.ipcAlias)") { SessionActions.copy(session.ipcAlias) }
                .disabled(session.ipcAlias.isEmpty)
        }
    }

    private func icon(_ name: String, _ help: String, act: @escaping () -> Void) -> some View {
        Button {
            act()
            if name != "terminal" {
                copied = name
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == name { copied = nil } }
            }
        } label: {
            Image(systemName: copied == name ? "checkmark" : name).font(.sbIcon(10.5, weight: .medium))
                .frame(width: si(14))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied == name ? Color(nsColor: menuGreen) : .secondary)
        .help(copied == name ? "Copied" : help)
    }
}

/// The session that has waited longest: its name, how long, and Claude's last words in full.
struct HeroCard: View {
    let session: LiveSession
    let now: Date
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Attention.needsYou.color).frame(width: si(7), height: si(7))
                Text(session.title).font(.sb(12, weight: .semibold))
                Text("waiting \(SessionScan.age(since: session.since, now: now))")
                    .font(.sb(11)).foregroundStyle(Attention.needsYou.color)
                Spacer(minLength: 4)
                SessionIcons(session: session)
            }
            Text(session.lastReply.isEmpty ? "Claude finished its turn." : session.lastReply)
                .font(.sb(11.5)).fixedSize(horizontal: false, vertical: true)
            Button(action: open) { Label("Open transcript", systemImage: "text.bubble") }
                .sbControlSize(.small)
                .help("Read the whole session in the hub")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help(SessionRow.detail(session))
    }
}

/// One session on one line: state dot, name, what it is doing, for how long,
/// context left, and the three icons. A click opens the transcript.
struct SessionRow: View {
    let session: LiveSession
    let now: Date
    var busy = false
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            // a Button, not a tap gesture: the card is not the key window, and only buttons take that first click
            Button(action: open) { HStack(spacing: 6) {
                Circle().fill(session.attention.color).frame(width: si(6), height: si(6))
                    // a working session looks alive; waiting is not activity, so needs-you stays still
                    .overlay { if session.attention == .working { AlivePulse(color: session.attention.color, size: si(6)) } }
                Text(session.title).font(.sb(11.5, weight: .medium)).lineLimit(1)
                Text(stateWord).font(.sb(10.5))
                    .foregroundStyle(session.attention == .needsYou ? session.attention.color : .secondary).lineLimit(1)
                Spacer(minLength: 4)
                if busy { ProgressView().sbControlSize(.mini) }
                Text(SessionScan.age(since: session.since, now: now))
                    .font(.sb(10.5).monospacedDigit()).foregroundStyle(.secondary)
                if let c = session.ctxLeft { ctxBar(c) }
            }
            .contentShape(Rectangle()) }
            .buttonStyle(.plain)
            SessionIcons(session: session)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .padding(.horizontal, -4)
        .onHover { hover = $0 }
        .help(Self.detail(session))
    }

    private var stateWord: String {
        switch session.attention {
        case .needsYou: return "your turn"
        case .working: return session.doing
        case .idle: return "idle"
        }
    }

    private func ctxBar(_ left: Int) -> some View {
        let tint: Color = left < 25 ? .red : Attention.working.color
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(tint).frame(width: max(2, 26 * CGFloat(min(left, 100)) / 100))
        }
        .frame(width: sc(26), height: sc(4))
        .help("\(left)% of its context left")
    }

    /// The hover detail: everything the row leaves out, one fact a line.
    static func detail(_ s: LiveSession) -> String {
        var lines = [s.title, s.cwdShort.isEmpty ? s.cwd : s.cwdShort]
        if !s.branch.isEmpty { lines.append("Branch: \(s.branch)") }
        if !s.model.isEmpty { lines.append("Model: \(s.model)") }
        if let c = s.ctxLeft { lines.append("Context left: \(c)%") }
        lines.append("Tokens: \(s.tokens.formatted())")
        if let c = s.costUSD { lines.append(String(format: "Cost: $%.2f", c)) }
        if let m = s.memoryMB { lines.append("Memory: \(m) MB") }
        if !s.lastPrompt.isEmpty { lines.append("Last prompt: \(s.lastPrompt)") }
        if !s.focusFile.isEmpty { lines.append("Focus file: \(s.focusFile)") }
        return lines.joined(separator: "\n")
    }
}

// ── Checks ──────────────────────────────────────────────────────────────────

/// The card's rules without a scanner: grouping, order, the hero, a gone
/// session dropping out, and the scan fields the card relies on.
/// With a path, also checks that file (a real scan) carries every used field.
func probeSessions(scanFile: String?) -> String {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let now = Date(timeIntervalSince1970: 100_000)
    func iso(_ minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
    }
    func row(_ sid: String, _ att: String, _ ago: Double, pid: Int = 1, reply: String = "") -> [String: Any] {
        ["session_id": sid, "pid": pid, "name": sid, "cwd": "/tmp/\(sid)", "cwd_short": "/tmp/\(sid)",
         "attention": att, "status_since": iso(ago), "session_state": ["state": "tool_use", "detail": "Bash: ls"],
         "last_reply": reply, "last_prompt": "", "model": "opus", "git_branch": "", "cost_usd": 1.5,
         "input_tokens": 1, "output_tokens": 2, "statusline": ["ctx_remaining": "40", "rss_mb": "100", "focus_file": ""],
         "ipc": NSNull()]
    }
    func scan(_ rows: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: ["live": rows]) }

    let rows = [row("idle-old", "idle", 300), row("work-new", "working", 2), row("you-short", "needs_you", 5),
                row("idle-new", "idle", 90), row("work-old", "working", 40), row("you-long", "needs_you", 20, reply: "Should I push?")]
    let list = SessionScan.ordered(SessionScan.parse(scan(rows)) ?? [])
    check("needs you, then working, then idle; longest wait and longest run first, newest idle first",
          list.map(\.id) == ["you-long", "you-short", "work-old", "work-new", "idle-new", "idle-old"], list.map(\.id).joined(separator: ","))
    let hero = SessionScan.hero(list)
    check("the hero is the session that has waited longest", hero?.id == "you-long" && hero?.lastReply == "Should I push?", hero?.id ?? "none")
    check("with nothing waiting there is no hero",
          SessionScan.hero(SessionScan.ordered(SessionScan.parse(scan([row("w", "working", 1)])) ?? [])) == nil)
    let next = SessionScan.parse(scan(rows.filter { ($0["session_id"] as? String) != "idle-old" })) ?? []
    check("a session whose process is gone drops out on the next scan", !next.contains { $0.id == "idle-old" } && next.count == 5)
    check("a tool in use reads as its name", SessionScan.doingWord(state: "tool_use", detail: "Bash: git status") == "Bash")
    check("ages read now, minutes, hours, days",
          ["now", "20m", "3h", "2d"] == [0.5, 20, 180, 2900].map { SessionScan.age(since: now.addingTimeInterval(-$0 * 60), now: now) })
    check("a full recorded row carries every used field", SessionScan.missingFields(scan(rows)).isEmpty)
    var broken = rows[0]; broken.removeValue(forKey: "attention")
    check("a row missing a used field is named", SessionScan.missingFields(scan([broken])) == ["attention"],
          SessionScan.missingFields(scan([broken])).joined(separator: ","))
    if let path = scanFile {
        if let d = FileManager.default.contents(atPath: path) {
            let missing = SessionScan.missingFields(d)
            check("the scanner's output carries every field the card reads", missing.isEmpty, missing.joined(separator: ", "))
        } else {
            check("the scan file can be read", false, path)
        }
    }
    let failed = lines.contains { $0.hasPrefix("FAIL") }
    return (lines + [failed ? "some failed" : "all passed"]).joined(separator: "\n")
}
