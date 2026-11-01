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
    var copies = 0
    NotesStore.remindersOff = false
    let rs = NotesStore()
    rs.reminders = ReminderBackend(status: { .fullAccess }, requestAccess: { $0(true) }, save: { _ in copies += 1; return "r1" }, remove: { _ in nil })
    var r = rs.add(title: "Ring me", body: "x")!
    r.remindAt = Date().addingTimeInterval(3600); rs.update(r)
    check("with the app not yet ringing, Reminders.app still gets the copy", copies == 1, "\(copies)")
    ReminderRinger.shared.start()
    var r2 = rs.add(title: "Ring me too", body: "y")!
    r2.remindAt = Date().addingTimeInterval(3600); rs.update(r2)
    check("once the app rings for itself, a new reminder makes no Reminders.app copy", copies == 1, "\(copies)")
    ReminderRinger.shared.stopWatching()
    NotesStore.remindersOff = true

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
