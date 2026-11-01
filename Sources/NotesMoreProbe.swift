// NotesMoreProbe.swift
// Headless checks for Recently deleted from git history, the attachment rule, tables and attachment links in the
// reader, the Reminders.app copy being skipped while the app rings, the waiting badges, and renaming a tag.
// Scratch folder with its own repository; nothing here touches the owner's notes.

import Foundation

func probeNotesMore() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "sb-more-\(getpid())"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/notes/attachments", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let defaults = NotesStore.defaults
    let oldFolder = defaults.string(forKey: NotesStore.folderKey)
    defaults.set(root + "/notes", forKey: NotesStore.folderKey)
    defaults.removeObject(forKey: NotesSync.remoteKey)
    defaults.removeObject(forKey: NotesStore.historyHiddenKey)
    defer { if let f = oldFolder { defaults.set(f, forKey: NotesStore.folderKey) } else { defaults.removeObject(forKey: NotesStore.folderKey) } }
    @discardableResult func g(_ a: String...) -> GitResult { NotesSync.runGit(a, cwd: root + "/notes") }
    func put(_ f: String, _ t: String) {
        try? fm.createDirectory(atPath: (root + "/notes/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? t.write(toFile: root + "/notes/" + f, atomically: true, encoding: .utf8)
    }
    func exists(_ f: String) -> Bool { fm.fileExists(atPath: root + "/notes/" + f) }

    NotesStore.remindersOff = true
    let sync = NotesSync.shared
    _ = sync.ensureRepo()
    g("config", "user.name", "T"); g("config", "user.email", "t@t")
    let s = NotesStore()

    // Recently deleted reads git history, so a note deleted on another device is listed too
    put("gone.md", "---\ntitle: \"Deleted elsewhere\"\n---\nwords that were here\n")
    sync.commitNow("save")
    try? fm.removeItem(atPath: root + "/notes/gone.md")
    sync.commitNow("delete on the phone")
    s.load()
    let found = s.trashed.first { $0.note.id == "gone" }
    check("a note deleted in git history, not in .trash, is listed under Recently deleted with its words", found?.note.title == "Deleted elsewhere" && found?.historyText?.contains("words that were here") == true, "\(s.trashed.map(\.note.id))")
    if let f = found, let back = s.restore(f) {
        check("restoring it writes the file again with its text", back.body == "words that were here" && exists("gone.md"))
    } else { check("restoring it writes the file again with its text", false) }
    check("a restored note leaves the list", !s.trashed.contains { $0.note.id == "gone" })

    // a note owns nothing by file name: an attachment goes only when no other note or save links to it
    put("attachments/shared.png", "png"); put("attachments/own.pdf", "pdf"); put("attachments/my pic.png", "png")
    guard let a = s.add(title: "A", body: "![shared](attachments/shared.png)\n[the file](attachments/own.pdf)\n![](attachments/my%20pic.png)"),
          let b = s.add(title: "B", body: "also ![shared](attachments/shared.png)") else { return lines + ["FAIL attachment notes were not made"] }
    check("attachment links are found, percent-decoded, for pictures and other files",
          NotesStore.attachmentPaths(in: a.body) == ["attachments/shared.png", "attachments/own.pdf", "attachments/my pic.png"], "\(NotesStore.attachmentPaths(in: a.body))")
    s.delete(a)
    check("deleting a note removes an attachment only it linked to", !exists("attachments/own.pdf") && !exists("attachments/my pic.png"))
    check("and keeps one another note still links to", exists("attachments/shared.png"))
    if let t = s.trashed.first(where: { $0.note.id == a.id }) { _ = s.restore(t) }
    check("restoring the note brings its attachments back", exists("attachments/own.pdf") && exists("attachments/my pic.png"))
    SavedStore().add(url: "https://example.com/x", title: "Saves link too")   // a save with a link of its own does not hold files
    s.delete(b)
    check("a file the restored note still links to is kept when the last other note goes", exists("attachments/shared.png"))

    // the reader: tables, and links into attachments that open
    let tb = MarkdownBody.blocks("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 |\ntext")
    check("a pipe table becomes one table block with its rows, and the line after it a paragraph",
          tb == [.table(["a", "b"], [["1", "2"], ["3"]]), .para("text")], "\(tb)")
    check("pipes with no separator row stay plain lines", MarkdownBody.blocks("| not | a table |") == [.para("| not | a table |")])

    // Reminders.app gets no copy while the app itself rings
    var copies = 0, removed = 0
    NotesStore.remindersOff = false
    let rs = NotesStore()
    rs.reminders = ReminderBackend(status: { .fullAccess }, requestAccess: { $0(true) }, save: { _ in copies += 1; return "r1" }, remove: { _ in removed += 1; return nil })
    var r = rs.add(title: "Ring me", body: "x")!
    r.remindAt = Date().addingTimeInterval(3600); rs.update(r)
    check("Reminders.app keeps an item for a reminder, as the fallback for when the app is quit", copies == 1, "\(copies)")
    ReminderRinger.shared.start()
    var r2 = rs.add(title: "Ring me too", body: "y")!
    r2.remindAt = Date().addingTimeInterval(-30); rs.update(r2)
    check("it does so while the app is running too", copies == 2, "\(copies)")
    ReminderRinger.shared.stopWatching()
    let dismisser = ReminderRinger()
    dismisser.dismiss(r2.id, notes: rs, now: Date())
    check("dismissing the reminder removes its Reminders.app item, so a running app does not notify twice", removed == 1, "\(removed)")
    NotesStore.remindersOff = true

    // S4: every way of writing a link to a picture keeps the picture while another note still shows it
    let forms = ["![x](./attachments/f1.png)", "![x](<attachments/f2.png>)", "![x](attachments/f3.png \"caption\")", "[ref]: attachments/f4.png",
                 "<img src=\"attachments/f5.png\">", "![x](attachments/a(1).png)", "![x](attachments/f7%20s.png)"]
    let names = ["f1.png", "f2.png", "f3.png", "f4.png", "f5.png", "a(1).png", "f7 s.png"]
    for (i, f) in forms.enumerated() {
        put("attachments/" + names[i], "png")
        let owner = s.add(title: "Owner \(i)", body: "![mine](attachments/" + names[i].replacingOccurrences(of: " ", with: "%20") + ")")!
        _ = s.add(title: "Other \(i)", body: f)
        s.delete(owner)
        check("deleting a note keeps a picture another note links to as \(f)", exists("attachments/" + names[i]))
    }

    // S5: reading the trash does not run git on the caller's thread; the history arrives off the main thread
    put("later.md", "---\ntitle: \"Deleted for the history read\"\n---\nbody\n"); sync.commitNow("save")
    try? fm.removeItem(atPath: root + "/notes/later.md"); sync.commitNow("delete on the phone")
    let quick = NotesStore()
    quick.loadTrash()
    check("loadTrash does not read git history before returning", !quick.trashed.contains { $0.note.id == "later" })
    let until = Date().addingTimeInterval(8)
    while !quick.trashed.contains(where: { $0.note.id == "later" }), Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check("and the history shows once it has been read in the background", quick.trashed.contains { $0.note.id == "later" })

    // S7: removed for good stays removed, even though the deletion is in git history
    let doomed = s.add(title: "Remove me for good", body: "z")!
    sync.commitNow("save")
    s.delete(doomed); sync.commitNow("delete")
    s.load()
    if let t = s.trashed.first(where: { $0.note.id == doomed.id }) { s.purge(t) }
    s.load()
    check("a note removed for good does not come back from git history", !s.trashed.contains { $0.note.id == doomed.id })

    // S8: restoring from history brings its picture back
    put("attachments/hist.png", "png")
    put("withpic.md", "---\ntitle: \"With a picture\"\n---\n![p](attachments/hist.png)\n"); sync.commitNow("save")
    try? fm.removeItem(atPath: root + "/notes/withpic.md"); try? fm.removeItem(atPath: root + "/notes/attachments/hist.png"); sync.commitNow("delete on the phone")
    s.load()
    if let t = s.trashed.first(where: { $0.note.id == "withpic" }) { _ = s.restore(t) }
    check("restoring a note from git history brings its picture back too", exists("withpic.md") && exists("attachments/hist.png"))

    // S9: a removed save can be brought back
    let keepSave = SavedStore.shared.add(url: "https://example.com/undo-me", title: "Undo me")!
    SavedStore.shared.remove(key: keepSave.id)
    sync.commitNow("save")
    s.load()
    let trashedSave = s.trashed.first { $0.isSave && $0.note.id == keepSave.id }
    check("a removed save is set aside in .trash/.saved and listed under Recently deleted", exists(".trash/.saved/\(keepSave.id).md") && trashedSave != nil)
    if let t = trashedSave { _ = s.restore(t) }
    check("restoring it puts it back in .saved", exists(".saved/\(keepSave.id).md"))

    // S10: renaming a tag reaches saves although the Saved tab was never opened this run
    let cold = SavedStore()
    _ = SavedStore.shared.add(url: "https://example.com/coldtag", title: "Cold", tags: ["coldold"])
    let renamed = TagRename.run("coldold", to: "coldnew", notes: s, saved: cold)
    check("a rename changes saves even when the store had not read the folder", renamed >= 1 && SavedStore.readAll().contains { $0.tags == ["coldnew"] }, "\(renamed)")
    // S10b: saving a link already saved does not overwrite it
    let again = cold.add(url: "https://example.com/coldtag", title: "Different title")
    check("saving a link that is already saved leaves its file and tags alone", again?.tags == ["coldnew"] && again?.title == "Cold", "\(String(describing: again?.tags))")

    // S6: an agent's note written straight into the folder reaches the lane, and what was there before does not
    let inbox = NotesInbox()
    inbox.resetSeen()
    try? fm.removeItem(atPath: NotesInbox.seenPath)
    put("old-agent.md", "---\ntitle: \"Older agent note\"\nagent: \"claude-1\"\n---\nbefore\n")
    s.load()
    inbox.observe(notes: s.notes, dir: root + "/notes")
    check("the first read only learns what exists: older agent notes are not put in the lane", inbox.lane().isEmpty)
    put("20261101-130000-aaaa.md", "---\ntitle: \"Agent wrote this on the Mac\"\nagent: \"claude-2\"\n---\nnew\n")
    put("20261101-130100-bbbb.md", "---\ntitle: \"A note I wrote\"\n---\nmine\n")
    s.load()
    inbox.observe(notes: s.notes, dir: root + "/notes")
    check("a new note an agent wrote on this Mac goes to the lane", inbox.lane().map(\.id) == ["20261101-130000-aaaa"], "\(inbox.lane().map(\.id))")
    check("and a new note of the owner's does not", inbox.waiting().isEmpty)
    try? fm.removeItem(atPath: NotesInbox.seenPath)

    // comments on a note, through bfb-docs, in the note's own folder; bfb's state goes to a scratch folder
    if NoteComments.toolPath == nil {
        lines.append("skip comments: bfb-docs is not installed here")
    } else {
        NoteComments.docsHome = root + "/bfbhome"
        let cn = s.add(title: "Commented", body: "Book the flights before Friday and ask about the visa.")!
        let before = (try? String(contentsOfFile: cn.path, encoding: .utf8)) ?? ""
        check("a new comment on words from the note is made through bfb-docs", NoteComments.add(to: cn.path, quote: "Book the flights before Friday", text: "Which airline?") == nil)
        var ts = NoteComments.threads(of: cn.path)
        check("it reads back as one open thread with the quote and the words", ts.count == 1 && ts[0].open && ts[0].quote == "Book the flights before Friday" && ts[0].comments.first?.text == "Which airline?", "\(ts)")
        check("the comment is written as the owner, not as an agent", NoteComments.parse(FileManager.default.contents(atPath: NoteComments.companion(of: cn.path)) ?? Data()).first?.comments.first?.author != "bfb")
        check("a reply joins the thread", ts.first.map { NoteComments.reply(in: cn.path, thread: $0.id, text: "Any direct one") } == .some(nil) && NoteComments.threads(of: cn.path).first?.comments.count == 2)
        check("a note's open comments are counted", NoteComments.openCount(of: cn.path) == 1)
        ts = NoteComments.threads(of: cn.path)
        check("Done closes the thread", ts.first.map { NoteComments.done(in: cn.path, thread: $0.id, text: "Booked") } == .some(nil) && NoteComments.openCount(of: cn.path) == 0)
        check("words that are not in the note are refused with a sentence, and make no thread", NoteComments.add(to: cn.path, quote: "words that are nowhere in it", text: "x") != nil)
        check("a comment never changes the note", ((try? String(contentsOfFile: cn.path, encoding: .utf8)) ?? "") == before)
        sync.commitNow("save")
        check("the companion file stays out of git", !g("ls-files").out.contains(".bfb.json"))
        NoteComments.docsHome = nil
    }

    // the waiting badges
    let ringer = ReminderRinger()
    var late = Note(id: "late", title: "Late", body: "", tags: [], created: Date())
    late.remindAt = Date().addingTimeInterval(-3600)
    let ids = NotesWaiting.badges(inbox: NotesInbox.shared, notes: [late], ringer: ringer).map(\.id)
    check("a missed reminder is on the waiting list", ids.contains("notes-missed"), "\(ids)")
    check("with nothing missed and nothing arrived there is no notes badge", NotesWaiting.badges(inbox: NotesInbox(), notes: [], ringer: ringer, now: Date()).filter { $0.id != "notes-inbox" && $0.id != "notes-agents" }.isEmpty)

    // renaming a tag on every note and save
    let ss = SavedStore.shared
    ss.load()
    var tagged = s.add(title: "Tagged", body: "z")!
    tagged.tags = ["old", "keep"]; s.update(tagged)
    let sv = ss.add(url: "https://example.com/tagged", title: "T", tags: ["old"])
    TagColors.set("old", to: "red")
    let changed = TagRename.run("old", to: "fresh", notes: s, saved: ss)
    check("renaming a tag changes every note and save that carries it", changed == 2 && s.notes.first { $0.id == tagged.id }?.tags == ["fresh", "keep"]
          && ss.items.first { $0.id == sv?.id }?.tags == ["fresh"], "\(changed)")
    check("and its colour moves with it", TagColors.read()["fresh"] == "red" && TagColors.read()["old"] == nil, "\(TagColors.read())")
    return lines
}
