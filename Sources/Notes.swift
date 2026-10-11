// Notes.swift
// Short notes the owner keeps at hand: one markdown file each, so a note's
// path can be handed to an agent. A note can expire (it dims and sinks to a
// collapsed Expired section; nothing is deleted) and can carry a reminder in
// macOS Reminders, once or on a repeat. The tab's view is in NotesView.swift.

import AppKit
import EventKit
import Foundation

/// Saves, reads back, expires, reorders and deletes notes in the state folder
/// the caller points SWITCHBOARD_STATE at; never touches Reminders.
func probeNotes() -> String {
    NotesStore.remindersOff = true
    NotesStore.probing = true
    NotesStore.defaults.removeObject(forKey: NotesStore.folderKey)
    let s = NotesStore()
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let a = s.add("Deploy: check \"prod\" first\nThe body line\nsecond line")
    check("a note is saved as a file", a.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    check("Enter on the same text does not save it twice", s.add("Deploy: check \"prod\" first\nThe body line\nsecond line")?.id == a?.id && s.notes.count == 1)
    let b = s.add("Second note")
    var edited = b!
    edited.tags = ["ops", "later"]
    edited.expires = Date().addingTimeInterval(-60)
    s.update(edited)
    s.load()
    let back = s.notes.first { $0.id == a?.id }
    check("a colon and quotes in the title survive the file", back?.title == "Deploy: check \"prod\" first", back?.title ?? "nil")
    check("the body survives the file", back?.body == "The body line\nsecond line", back?.body ?? "nil")
    let e = s.notes.first { $0.id == b?.id }
    check("tags survive the file", e?.tags == ["ops", "later"], e?.tags.joined(separator: ",") ?? "nil")
    var p = s.notes.first { $0.id == a?.id }!
    p.pinned = true
    s.update(p)
    s.load()
    check("a pin survives the file", s.notes.first { $0.id == a?.id }?.pinned == true)
    check("an unpinned note stays unpinned", s.notes.first { $0.id == b?.id }?.pinned == false)
    check("a past expiry moves the note to Expired", s.expired.map(\.id) == [b!.id] && s.live.map(\.id) == [a!.id])
    Thread.sleep(forTimeInterval: 1.1)   // a whole second apart, so "newest first" is what the file says too
    let c = s.add("Third")!
    check("a new note lands on top of its pin group", s.notes.map(\.id) == [a!.id, c.id, b!.id], s.notes.map(\.title).joined(separator: ","))
    func filesNow() -> [String: String] { Dictionary(uniqueKeysWithValues: s.notes.map { ($0.id, (try? String(contentsOfFile: $0.path, encoding: .utf8)) ?? "") }) }
    // a is pinned, so it stays above whatever is dragged below it; drag b onto c's place
    var beforeDrag = filesNow()
    s.move(b!.id, to: c.id)
    s.commitMove(visible: s.notes.map(\.id))
    s.load()
    check("a dragged order is kept across a reload", s.notes.map(\.id) == [a!.id, b!.id, c.id], s.notes.map(\.title).joined(separator: ","))
    check("the first drag arranges the group once: every unpinned note now has a pos", s.notes.filter { !$0.pinned }.allSatisfy { $0.pos != nil })
    beforeDrag = filesNow()
    s.move(c.id, to: b!.id)
    s.commitMove(visible: s.notes.map(\.id))
    s.load()
    let afterDrag = filesNow()
    check("a drag after that rewrites exactly one note", afterDrag.filter { beforeDrag[$0.key] != $0.value }.map(\.key) == [c.id],
          afterDrag.filter { beforeDrag[$0.key] != $0.value }.map(\.key).joined(separator: ","))
    check("and puts it back on top of its group", s.notes.map(\.id) == [a!.id, c.id, b!.id], s.notes.map(\.title).joined(separator: ","))
    s.move(a!.id, to: c.id)
    check("a row cannot be dragged across the pin line", s.notes.map(\.id) == [a!.id, c.id, b!.id])
    check("the old order file is never written", !FileManager.default.fileExists(atPath: NotesStore.dir + "/order.json"))
    s.delete(c)
    check("delete removes the file", !FileManager.default.fileExists(atPath: c.path) && !s.notes.contains { $0.id == c.id })
    // A header key Switchboard has no field for (another tool's, or typed by hand) survives a save here.
    let foreign = "---\ntitle: \"Kept\"\ncreated: 2026-10-11T00:00:00Z\nupdated: 2026-10-11\nmood: calm\ncolor: green\n---\nbody\n"
    var kept = NotesStore.parse(id: "x", foreign)!
    kept.body = "edited"
    let written = NotesStore.render(kept)
    check("an unknown header key survives a save", written.contains("\nupdated: 2026-10-11\n") && written.contains("\nmood: calm\n")
          && written.contains("\ncolor: green\n"), written)
    let listy = NotesStore.parse(id: "y", "---\ntitle: \"L\"\ntags:\n  - a\n  - b\n\nmood: calm\n---\nbody\n")!
    check("non-blank header lines without a colon are kept in order", listy.extra == ["  - a", "  - b", "mood: calm"], listy.extra.joined(separator: "|"))
    let bare = NotesStore.parse(id: "z", "---\ntitle: \"Z\"\nreminder_id: \"\"\n---\nbody\n")!
    let bareOut = NotesStore.render(bare)
    check("a note with no created line is saved without one", !bareOut.contains("created:") && !bareOut.contains("0001"), bareOut)
    check("an empty reminder id is not written", !bareOut.contains("reminder_id"), bareOut)

    // A folder chosen in Settings that has gone missing is reported, never quietly re-created empty.
    let savedFolder = NotesStore.defaults.string(forKey: NotesStore.folderKey)
    let gone = NSTemporaryDirectory() + "sb-notes-missing-\(getpid())"
    NotesStore.defaults.set(gone, forKey: NotesStore.folderKey)
    let lost = NotesStore()
    lost.load()
    check("a missing chosen folder is said to be missing and not created",
          lost.loaded && lost.notes.isEmpty && lost.error?.contains("is missing") == true && !FileManager.default.fileExists(atPath: gone),
          lost.error ?? "nil")
    check("saving into it fails with that sentence and still creates nothing",
          lost.add("lost note") == nil && lost.error?.contains("is missing") == true && !FileManager.default.fileExists(atPath: gone))
    if let b = savedFolder { NotesStore.defaults.set(b, forKey: NotesStore.folderKey) } else { NotesStore.defaults.removeObject(forKey: NotesStore.folderKey) }
    check("a store that has not read yet is not loaded", !NotesStore().loaded)
    check("the probe's folder choice never touches the app's own defaults",
          UserDefaults.standard.string(forKey: NotesStore.folderKey) != gone && NotesStore.probing)

    // Reminders through a stand-in: the permission dialog stays up until answer() runs.
    NotesStore.remindersOff = false
    var status = EKAuthorizationStatus.notDetermined
    var answer: ((Bool) -> Void)?
    var saved: [Note] = []
    var saveFails = false
    s.reminders = ReminderBackend(status: { status }, requestAccess: { answer = $0 },
                                  save: { n in
                                      if saveFails { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "calendar is read-only"]) }
                                      saved.append(n); return "rem-\(saved.count)" },
                                  remove: { _ in nil })
    func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    var r = s.add("Call the bank")!
    r.remindAt = Date().addingTimeInterval(3600)
    s.update(r)
    r.body = "typed while the dialog was up"
    s.update(r)
    status = .fullAccess
    answer?(true); pump()
    let after = s.notes.first { $0.id == r.id }
    check("the first reminder is created once access is given", saved.count == 1, "\(saved.count) saved")
    check("it carries what was typed while the dialog was up", saved.first?.body == "typed while the dialog was up"
          && after?.body == "typed while the dialog was up", after?.body ?? "nil")
    check("the note records its reminder", after?.reminderID == "rem-1", after?.reminderID ?? "nil")
    status = .denied
    var d = s.add("Denied one")!
    d.remindAt = Date().addingTimeInterval(3600)
    s.update(d)
    check("no access says so instead of passing quietly", s.error?.contains("may not add reminders") == true, s.error ?? "nil")
    status = .fullAccess; saveFails = true
    var f = s.add("Failing save")!
    f.remindAt = Date().addingTimeInterval(3600)
    s.update(f)
    check("a failed save says why", s.error?.contains("read-only") == true, s.error ?? "nil")
    NotesStore.remindersOff = true

    // A folder of the owner's own, holding a markdown file written by hand.
    let ud = NotesStore.defaults
    let chosenBefore = ud.string(forKey: NotesStore.folderKey)
    let own = AppPaths.stateDir + "/own-notes"
    // The owner's own folder exists already; the store never creates a chosen one.
    try? FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
    ud.set(own, forKey: NotesStore.folderKey)
    try? "# Shopping\n\n- milk\n- eggs\n".write(toFile: NotesStore.dir + "/shopping.md", atomically: true, encoding: .utf8)
    s.load()
    var h = s.notes.first { $0.id == "shopping" }
    check("a hand-written file reads its heading as the title", h?.title == "Shopping", h?.title ?? "nil")
    check("and keeps its body", h?.body == "- milk\n- eggs", h?.body ?? "nil")
    h?.tags = ["errands"]
    if let h = h { s.update(h) }
    let onDisk = (try? String(contentsOfFile: own + "/shopping.md", encoding: .utf8)) ?? ""
    check("editing it keeps the body in the file", onDisk.contains("- milk\n- eggs"), onDisk)
    check("the saved order is not written into the owner's folder", !FileManager.default.fileExists(atPath: own + "/order.json"))
    ud.set(chosenBefore, forKey: NotesStore.folderKey)

    // Title and body, either one optional, never both empty; a colour tag survives the file.
    check("a note with only a body is saved", s.add(title: "", body: "just the text")?.heading == "just the text")
    check("a note with neither is refused", s.add(title: "  ", body: "\n") == nil)
    let tinted = s.add(title: "Tinted", body: "", color: "purple")!
    s.load()
    check("a colour tag survives the file", s.notes.first { $0.id == tinted.id }?.color == "purple")
    check("there are eight tag colours, the Reminders set with green and yellow",
          timerColors.map(\.0) == ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"])
    check("an old colour name lands on its new one", tagColorName("indigo") == "purple" && tagColorName("mint") == "green"
          && tagColorName("gray") == "blue" && tagColorName("green") == "green" && tagColorName("plaid") == nil)
    let nobody = InputRules.copyButtons(title: "Only title", body: "")
    let notitle = InputRules.copyButtons(title: "", body: "only body")
    check("a title-only note offers only the title copy", nobody.title && !nobody.body)
    check("a body-only note offers only the text copy", notitle.body && !notitle.title)

    // Enter in a title: the rest of the line goes to the top of the body.
    let mid = InputRules.splitTitle(before: "Buy ", after: "milk and eggs", body: "")
    check("Enter mid-title moves the rest into an empty body", mid == ("Buy", "milk and eggs"), "\(mid)")
    let onto = InputRules.splitTitle(before: "Buy ", after: "milk", body: "at the shop")
    check("into a body that has text, on its own line above it", onto == ("Buy", "milk\nat the shop"), "\(onto)")
    let end = InputRules.splitTitle(before: "Buy milk", after: "", body: "at the shop")
    check("Enter at the end of a title leaves the body as it was", end == ("Buy milk", "at the shop"), "\(end)")

    // Opening a tab: the new input takes the keyboard unless something is being edited.
    check("the new input is focused when nothing is being edited", InputRules.focusNewInput(editing: nil))
    check("an edit in progress keeps the keyboard", !InputRules.focusNewInput(editing: "20261001-120000"))

    // A note holding both sides of a clash settles to one side, or both, with nothing else lost.
    let clash = "top\n<<<<<<< HEAD\nmac line\n=======\npi line\n>>>>>>> pi/main\nmiddle\n<<<<<<< phone\nA\n=======\nB\n>>>>>>> csync-pi\nend"
    check("resolve keeps mine", NotesSync.resolve(clash, keep: .mine) == "top\nmac line\nmiddle\nA\nend")
    check("resolve keeps theirs", NotesSync.resolve(clash, keep: .theirs) == "top\npi line\nmiddle\nB\nend")
    check("resolve keeps both, mine first", NotesSync.resolve(clash, keep: .both) == "top\nmac line\npi line\nmiddle\nA\nB\nend")
    check("a resolved note is no longer a clash", !NotesSync.conflicted(NotesSync.resolve(clash, keep: .both)))
    check("an unclosed block loses nothing", NotesSync.resolve("a\n<<<<<<< x\nb\n=======\nc", keep: .mine) == "a\nb\nc")

    // Delete puts a note in .trash; Recently deleted brings it back or removes it for good.
    // earlier checks deleted notes too; start this one from an empty .trash
    try? FileManager.default.removeItem(atPath: NotesStore.trashDir)
    s.loadTrash()
    let doomed = s.add("Delete me\nbody kept")!
    s.delete(doomed)
    check("delete moves the file to .trash", !FileManager.default.fileExists(atPath: doomed.path)
          && FileManager.default.fileExists(atPath: NotesStore.trashDir + "/" + doomed.id + ".md"))
    check("the deleted note is listed with its title", s.trashed.map(\.note.title) == ["Delete me"], s.trashed.map(\.note.title).joined(separator: ","))
    check("it is gone from the notes", !s.notes.contains { $0.id == doomed.id })
    check("restore brings it back with its text", s.restore(s.trashed[0])?.body == "body kept" && s.trashed.isEmpty && s.notes.contains { $0.id == doomed.id })
    let twin = s.add("Twin")!
    s.delete(twin)
    let again = s.add("Twin")!
    s.delete(again)
    check("two deleted notes of one name are both kept", s.trashed.count == 2, "\(s.trashed.count)")
    let holder = s.add("Holder")!
    s.delete(holder)
    let sameID = NotesStore.dir + "/" + holder.id + ".md"
    try? "---\ntitle: \"Squatter\"\n---\nx\n".write(toFile: sameID, atomically: true, encoding: .utf8)
    s.load()
    let revived = s.restore(s.trashed.first { $0.note.title == "Holder" }!)
    check("a restore never overwrites a note that took its name", revived?.title == "Holder" && revived?.id != holder.id
          && s.notes.first { $0.id == holder.id }?.title == "Squatter")
    var reminded = s.add("Remind me")!
    reminded.remindAt = Date().addingTimeInterval(3600)
    s.update(reminded)
    s.delete(s.notes.first { $0.id == reminded.id }!)
    check("a restored note comes back without its reminder", s.restore(s.trashed.first { $0.note.title == "Remind me" }!)?.remindAt == nil)
    s.purge(s.trashed[0])
    check("remove for good takes it out of the list", s.trashed.count == 1, "\(s.trashed.count)")
    for t in s.trashed { s.purge(t) }
    check("the hidden folder is not read as notes", !s.notes.contains { $0.id.hasPrefix(".") })

    // Duplicate: the same words, tags, colour and link, but never the pin or a reminder.
    var src = s.add(title: "Source", body: "words", color: "blue", url: "https://example.com/s")!
    src.tags = ["t1"]; src.pinned = true
    src.remindAt = Date().addingTimeInterval(3600)
    s.update(src)
    Thread.sleep(forTimeInterval: 1.1)
    let dup = s.duplicate(s.notes.first { $0.id == src.id }!)
    s.load()
    let dupBack = s.notes.first { $0.id == dup?.id }
    check("a duplicate keeps the words, tags, colour and link", dupBack?.title == "Source copy" && dupBack?.body == "words"
          && dupBack?.tags == ["t1"] && dupBack?.color == "blue" && dupBack?.url == "https://example.com/s")
    check("a duplicate is not pinned and has no reminder", dupBack?.pinned == false && dupBack?.remindAt == nil && dupBack?.reminderID == nil)
    check("the original is left as it was", s.notes.first { $0.id == src.id }?.pinned == true && s.notes.first { $0.id == src.id }?.title == "Source")
    check("a copy of a pinned note starts the unpinned notes", s.notes.first { !$0.pinned }?.id == dup?.id)
    Thread.sleep(forTimeInterval: 1.1)
    let plain = s.add("Plain original")!
    let plainCopy = s.duplicate(plain)
    check("a duplicate sits under its original", { let ids = s.notes.map(\.id); return (ids.firstIndex(of: plain.id) ?? -9) + 1 == ids.firstIndex(of: plainCopy?.id ?? "") }())

    // Show on the Pi: the address, the request, and a stand-in Pi that answers, refuses or is not there.
    check("the Pi's host is the notes remote's", PiLink.host(remote: "alcatraz627@100.65.188.9:Notes") == "100.65.188.9"
          && PiLink.host(remote: "me@pi.example:Notes.git") == "pi.example" && PiLink.host(remote: "") == PiLink.defaultHost)
    let req = PiLink.request(title: "T", body: "line one\nline two", base: "http://h:1", token: "tok")
    check("the request is a POST of the note's words with the token", req?.url?.absoluteString == "http://h:1/v1/display/show" && req?.httpMethod == "POST"
          && req?.value(forHTTPHeaderField: "X-Csync-Token") == "tok" && String(data: req?.httpBody ?? Data(), encoding: .utf8)?.contains("line one") == true)
    check("a title-only note shows its title", String(data: PiLink.request(title: "Only", body: "", base: "http://h:1", token: "t")?.httpBody ?? Data(), encoding: .utf8)?.contains("\"text\":\"Only\"") == true)
    check("a note with no words makes no request", PiLink.request(title: " ", body: "", base: "http://h:1", token: "t") == nil)
    check("long text is cut after a whole word under 4000", PiLink.screenText(String(repeating: "word ", count: 1200)).count <= 4000
          && PiLink.screenText(String(repeating: "word ", count: 1200)).hasSuffix("word"))
    /// A one-answer web server on the loopback address, standing in for the Pi.
    func piStub(status: String, body: String) -> (Int32, UInt16, () -> String)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: got.sin_port)
        let seen = NSMutableString()
        DispatchQueue.global().async {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            var all = Data()
            // read until the headers and the whole body have arrived
            while true {
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { break }
                all.append(buf, count: n)
                let text = String(data: all, encoding: .utf8) ?? ""
                if let r = text.range(of: "\r\n\r\n"),
                   let cl = text.lowercased().components(separatedBy: "content-length: ").dropFirst().first.flatMap({ Int($0.prefix { $0.isNumber }) }),
                   all.count >= text.distance(from: text.startIndex, to: r.upperBound) + cl { break }
            }
            DispatchQueue.main.sync { seen.append(String(data: all, encoding: .utf8) ?? "") }
            let r = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = r.withCString { send(c, $0, strlen($0), 0) }
            close(c)
        }
        return (fd, port, { seen as String })
    }
    func askPi(_ note: Note, base: String) -> (Bool, String) {
        PiLink.baseOverride = base
        PiLink.tokenOverride = "probe-token"
        var out: (Bool, String)?
        PiLink.show(note, remote: "") { ok, msg in out = (ok, msg) }
        let until = Date().addingTimeInterval(8)
        while out == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        PiLink.baseOverride = nil; PiLink.tokenOverride = nil
        return out ?? (false, "no answer")
    }
    if let (l, port, seen) = piStub(status: "200 OK", body: "{\"sentToDisplay\":true}") {
        let r = askPi(src, base: "http://127.0.0.1:\(port)")
        close(l)
        check("a Pi that answers is reported as showing", r.0 && r.1.contains("Showing"), r.1)
        check("the Pi got the path, the token and the words", seen().contains("POST /v1/display/show") && seen().lowercased().contains("x-csync-token: probe-token") && seen().contains("words"), seen())
    } else { check("a stand-in Pi starts", false) }
    if let (l, port, _) = piStub(status: "200 OK", body: "{\"sentToDisplay\":false}") {
        let r = askPi(src, base: "http://127.0.0.1:\(port)"); close(l)
        check("a Pi with its screen off says so", r.0 && r.1.contains("screen is off"), r.1)
    }
    if let (l, port, _) = piStub(status: "401 Unauthorized", body: "{}") {
        let r = askPi(src, base: "http://127.0.0.1:\(port)"); close(l)
        check("a refused token is said plainly", !r.0 && r.1.contains("token"), r.1)
    }
    let unreachable = askPi(src, base: "http://127.0.0.1:1")
    check("a Pi that is not there is a sentence, not a crash", !unreachable.0 && unreachable.1.contains("did not answer"), unreachable.1)

    // A link is a note by itself; sorts and the tag filter only change the view.
    let pin = s.add(title: "", body: "", url: "https://example.com/a")
    check("a note with only a link is saved and keeps it", pin != nil && pin?.heading == "https://example.com/a")
    s.load()
    check("the link survives the file", s.notes.first { $0.id == pin?.id }?.url == "https://example.com/a")
    func mk(_ id: String, _ title: String, _ day: Int, pinned: Bool = false, tags: [String] = []) -> Note {
        var n = Note(id: id, title: title, body: "", tags: tags, created: Date(timeIntervalSince1970: Double(day) * 86400))
        n.pinned = pinned
        return n
    }
    let set = [mk("a", "banana", 3, tags: ["x", "y"]), mk("b", "Apple", 1, pinned: true, tags: ["x"]), mk("c", "cherry", 2)]
    check("manual keeps the list as given", NoteSort.manual.apply(set).map(\.id) == ["a", "b", "c"])
    check("newest first, pinned still on top", NoteSort.newest.apply(set).map(\.id) == ["b", "a", "c"])
    check("oldest first, pinned still on top", NoteSort.oldest.apply(set).map(\.id) == ["b", "c", "a"])
    check("A to Z ignores case, pinned on top", NoteSort.title.apply(set).map(\.id) == ["b", "a", "c"])
    check("tags are counted, most used first", set.tagCounts.map(\.tag) == ["x", "y"] && set.tagCounts.map(\.count) == [2, 1])
    let nav = NotesNav()
    nav.sort = .manual
    nav.tagFilter = ["x"]
    check("one tag keeps the notes carrying it", nav.visible(set).map(\.id) == ["a", "b"])
    nav.tagFilter = ["x", "y"]
    check("two tags keep only notes with both", nav.visible(set).map(\.id) == ["a"])
    nav.tagFilter = []

    // The colour dots can be added to, renamed and removed; a note's file keeps the name it was saved with.
    let pal = NotePalette.shared
    pal.reset()
    NotePalette.customOn = false
    check("the palette starts as the shared eight", pal.dots.map(\.key) == timerColors.map(\.0))
    check("custom colours are off until the owner turns them on", !NotePalette.customOn)
    // Off: a custom dot may sit in the palette, but no picker offers it and no note file is given its name.
    let hidden = pal.add(label: "Hidden hue", hex: "#778899")
    let offNote = s.add(title: "Off note", body: "", color: "hidden-hue")
    check("while custom colours are off, a custom name is not written into a note",
          offNote?.color == nil && !((try? String(contentsOfFile: offNote?.path ?? "", encoding: .utf8)) ?? "").contains("color:"))
    check("and the pickers offer only the shared eight", hidden != nil && pal.colors.map(\.0) == timerColors.map(\.0), pal.colors.map(\.0).joined(separator: ","))
    check("a shared name is still written while they are off", s.add(title: "Shared hue", body: "", color: "red")?.color == "red")
    pal.reset()
    NotePalette.customOn = true
    check("turned on, the pickers offer the added dot", pal.add(label: "Seen hue", hex: "#778899") != nil && pal.colors.count == 9)
    pal.reset()
    let sea = pal.add(label: "Deep sea", hex: "#112233")
    check("an added dot's name is made from its label", sea?.key == "deep-sea" && pal.dots.count == 9, sea?.key ?? "nil")
    check("a second dot with the same label gets its own name", pal.add(label: "Deep sea", hex: "#445566")?.key == "deep-sea-2")
    check("an empty label or a bad colour adds nothing", pal.add(label: "  ", hex: "#112233") == nil && pal.add(label: "Bad", hex: "red") == nil && pal.dots.count == 10)
    pal.rename("red", to: "Urgent")
    check("a rename changes the label and keeps the file name", pal.label("red") == "Urgent" && noteColorName("red") == "red")
    check("the palette is read back from disk", NotePalette().dots == pal.dots)
    let deep = s.add(title: "Deep note", body: "", color: "deep-sea")!
    s.load()
    check("a note keeps an added dot's name across the file", s.notes.first { $0.id == deep.id }?.color == "deep-sea")
    check("the dot is in the note file by its name", ((try? String(contentsOfFile: deep.path, encoding: .utf8)) ?? "").contains("\ncolor: deep-sea\n"))
    pal.remove("deep-sea")
    s.load()
    check("a removed dot leaves its notes with no dot", s.notes.first { $0.id == deep.id }?.color == nil && noteColorName("deep-sea") == nil)
    pal.reset()
    check("reset brings back the shared eight", pal.dots == NotePalette.eight && pal.label("red") == "Red")
    check("the last dot cannot be removed", { let q = NotePalette(); for d in q.dots.dropFirst() { q.remove(d.key) }; q.remove(q.dots[0].key); let one = q.dots.count; q.reset(); return one == 1 }())
    NotePalette.customOn = false

    // The old order.json becomes pos lines once, and the clash rule keeps this Mac's side.
    let fm2 = FileManager.default
    let migBefore = NotesStore.defaults.string(forKey: NotesStore.folderKey)
    let mig = AppPaths.stateDir + "/migrate-notes"
    try? fm2.createDirectory(atPath: mig, withIntermediateDirectories: true)
    NotesStore.defaults.set(mig, forKey: NotesStore.folderKey)
    for (id, day) in [("m1", "09"), ("m2", "10"), ("m3", "08")] {
        try? "---\ntitle: \"\(id)\"\ncreated: 2026-10-\(day)T00:00:00Z\n---\nbody\n".write(toFile: mig + "/\(id).md", atomically: true, encoding: .utf8)
    }
    try? "[\"m3\",\"m1\",\"gone\"]".write(toFile: NotesStore.orderPath, atomically: true, encoding: .utf8)
    let ms = NotesStore()
    ms.load()
    func posOf(_ id: String) -> String? { ms.notes.first { $0.id == id }?.pos }
    check("migration gives the notes order.json names a pos, in its order", posOf("m3") != nil && posOf("m1") != nil && posOf("m3")! < posOf("m1")!, "\(posOf("m3") ?? "nil") \(posOf("m1") ?? "nil")")
    check("a note order.json never named stays unpositioned and so lands on top", posOf("m2") == nil && ms.notes.map(\.id) == ["m2", "m3", "m1"], ms.notes.map(\.id).joined(separator: ","))
    check("order.json is set aside, not deleted", !fm2.fileExists(atPath: NotesStore.orderPath) && fm2.fileExists(atPath: NotesStore.orderPath + ".migrated"))
    ms.load()
    check("a second load migrates nothing and keeps the order", ms.notes.map(\.id) == ["m2", "m3", "m1"])
    Thread.sleep(forTimeInterval: 2.6)   // the commit waits two seconds after the last write
    check("the migration is one commit, 'order: migrate'", NotesSync.shared.git(["log", "-1", "--format=%s"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "order: migrate",
          NotesSync.shared.git(["log", "-1", "--format=%s"]).out)
    if let b = migBefore { NotesStore.defaults.set(b, forKey: NotesStore.folderKey) } else { NotesStore.defaults.removeObject(forKey: NotesStore.folderKey) }
    // beside the default notes the set-aside file would sit inside the repository: an older repository learns to ignore it
    try? "order.json\n.DS_Store\n".write(toFile: NotesStore.dir + "/.gitignore", atomically: true, encoding: .utf8)
    NotesSync.shared.ensureRepo()
    try? "[]".write(toFile: NotesStore.dir + "/order.json.migrated", atomically: true, encoding: .utf8)
    check("an older repository ignores the set-aside order file", NotesSync.shared.git(["check-ignore", "order.json.migrated"]).code == 0)
    try? fm2.removeItem(atPath: NotesStore.dir + "/order.json.migrated")

    check("a clash that is only a pos line is recognised", NotesSync.posOnlyClash("---\ntitle: \"x\"\n<<<<<<< HEAD\npos: 4\n=======\npos: r\n>>>>>>> pi/main\n---\nbody\n"))
    check("a clash in the body is not", !NotesSync.posOnlyClash("---\ntitle: \"x\"\n---\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> pi/main\n"))
    check("a clash on pos and another line is not", !NotesSync.posOnlyClash("<<<<<<< HEAD\npos: 4\ncolor: red\n=======\npos: r\n>>>>>>> pi/main\n"))
    check("a text with no clash is not a pos clash", !NotesSync.posOnlyClash("---\npos: 4\n---\n"))
    let repo = NSTemporaryDirectory() + "sb-clash-\(getpid())"
    try? fm2.removeItem(atPath: repo)
    try? fm2.createDirectory(atPath: repo + "/.reminders/runs", withIntermediateDirectories: true)
    @discardableResult func g(_ a: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo] + a
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (127, "", "\(error)") }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }
    func put(_ f: String, _ t: String) { try? t.write(toFile: repo + "/" + f, atomically: true, encoding: .utf8) }
    func note(pos: String, body: String) -> String { "---\ntitle: \"A\"\ncreated: 2026-10-01T00:00:00Z\npos: \(pos)\n---\n\(body)\n" }
    g(["init", "-q", "-b", "main"]); g(["config", "user.name", "t"]); g(["config", "user.email", "t@t"])
    put("a.md", note(pos: "i", body: "one")); put("b.md", note(pos: "i", body: "one")); put(".reminders/runs/r.json", "{\"v\":0}\n")
    g(["add", "-A"]); g(["commit", "-q", "-m", "base"])
    g(["checkout", "-q", "-b", "side"])
    put("a.md", note(pos: "r", body: "one")); put("b.md", note(pos: "i", body: "phone body")); put(".reminders/runs/r.json", "{\"v\":2}\n")
    g(["commit", "-q", "-am", "phone"])
    g(["checkout", "-q", "main"])
    put("a.md", note(pos: "4", body: "one")); put("b.md", note(pos: "i", body: "mac body")); put(".reminders/runs/r.json", "{\"v\":1}\n")
    g(["commit", "-q", "-am", "mac"])
    check("the scratch merge stops on three clashes", g(["merge", "-q", "--no-edit", "side"]).code != 0)
    NotesSync.settleClashes(in: repo, git: { g($0) })
    g(["add", "-A"])
    let merged = g(["commit", "-q", "-m", "merge"])
    let aText = (try? String(contentsOfFile: repo + "/a.md", encoding: .utf8)) ?? ""
    let rText = (try? String(contentsOfFile: repo + "/.reminders/runs/r.json", encoding: .utf8)) ?? ""
    let bText = (try? String(contentsOfFile: repo + "/b.md", encoding: .utf8)) ?? ""
    check("a note moved on both sides keeps the Mac's pos and no markers", aText.contains("\npos: 4\n") && !aText.contains("<<<<<<<") && !aText.contains("pos: r"), aText)
    check("a clash under .reminders keeps the Mac's file whole", rText == "{\"v\":1}\n", rText)
    check("a body clash keeps both sides, as before", bText.contains("<<<<<<<") && bText.contains("mac body") && bText.contains("phone body"))
    check("the merge commits after the rules ran", merged.code == 0, merged.err)
    try? fm2.removeItem(atPath: repo)
    lines.append(lines.contains { $0.hasPrefix("FAIL") } ? "some failed" : "all passed")
    return lines.joined(separator: "\n")
}

struct Note: Identifiable, Equatable {
    enum Repeat: String, CaseIterable { case never, daily, weekly, monthly }

    let id: String
    var title: String
    var body: String
    var tags: [String]
    var created: Date
    var expires: Date?
    var remindAt: Date?
    var remindRepeat: Repeat = .never
    /// The Reminders item this note owns, so it can be changed or removed.
    var reminderID: String?
    /// Pinned notes are the ones the menu-bar quick page lists.
    var pinned = false
    /// A colour tag, one of the timer colours by name; nil for none.
    var color: String? = nil
    /// The agent that wrote or last edited it ("pi"); a person's edit never clears it.
    var agent: String? = nil
    /// Where an imported note came from ("csync").
    var source: String? = nil
    /// A pin is a note with a link: title, body and url are each optional, one is needed.
    var url: String? = nil
    /// Where the note sits in the shared order, written bare; nil until it is first arranged. See NotePos.
    var pos: String? = nil
    /// Header lines Switchboard has no field for, written back as they were, so a key
    /// another tool or a person added is never lost on a save here.
    var extra: [String] = []

    var expired: Bool { expires.map { $0 <= Date() } ?? false }
    /// Both sides of a clash are in the body, marked by git; the owner sorts it out when they like.
    var conflicted: Bool { NotesSync.conflicted(body) }
    /// When the note's file last changed, which is when it was last edited.
    /// By its last commit when there is one (a sync touches every file's own time), else the file's time.
    var modified: Date? {
        NotesSync.shared.editTime(id) ?? (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    /// Pinned, or edited in the last two hours: shown as a row on the hover card, not a chip.
    static func keepsRow(pinned: Bool, modified: Date?, now: Date = Date()) -> Bool {
        pinned || (modified.map { now.timeIntervalSince($0) < 2 * 3600 } ?? false)
    }
    var path: String { NotesStore.dir + "/" + id + ".md" }
    /// Title and body as one text, the way Copy content hands it over.
    var content: String { body.isEmpty ? title : title.isEmpty ? body : title + "\n\n" + body }
    /// What a list shows as the note's name: the title, or the body's first line when there is no title.
    var heading: String {
        title.isEmpty ? (body.components(separatedBy: "\n").first { !$0.isEmpty } ?? url ?? "") : title
    }
}

final class NotesStore: ObservableObject {
    /// The one store the tab and the hover preview share.
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var error: String?
    /// A short word on something that just happened (duplicated, shown on the Pi); it clears itself.
    struct Notice: Equatable { let text: String; let ok: Bool }
    @Published private(set) var notice: Notice?
    func say(_ text: String, ok: Bool = true) {
        let n = Notice(text: text, ok: ok)
        notice = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.notice == n { self?.notice = nil } }
    }
    /// True once the folder has been read, so an empty list can say "No notes yet" and not "still reading".
    @Published private(set) var loaded = false

    /// Where notes are kept: the folder chosen in Settings, or the state folder's notes.
    static let folderKey = "switchboard.notesFolder"
    /// Set by --probe-notes so the folder choice is read and written in a throwaway suite, never the app's own domain.
    static var probing = false
    static var defaults: UserDefaults {
        probing ? (UserDefaults(suiteName: "switchboard.probe-notes") ?? .standard) : .standard
    }
    /// `~/Notes`, the one folder the Mac, the Pi and the phone share (contract 2026-10-10).
    /// A probe's scratch state keeps its own folder so no check ever touches the owner's notes.
    static var defaultDir: String {
        ProcessInfo.processInfo.environment["SWITCHBOARD_STATE"] != nil ? AppPaths.stateDir + "/notes" : NSHomeDirectory() + "/Notes"
    }
    /// The first run after the move: the old state-folder notes come along once, then the old folder is left as it was.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        let old = AppPaths.stateDir + "/notes", new = NSHomeDirectory() + "/Notes"
        // `dir` creates an empty ~/Notes on first touch, so "nothing moved yet" means no .md there, not "absent"
        let already = ((try? fm.contentsOfDirectory(atPath: new)) ?? []).contains { $0.hasSuffix(".md") }
        guard ProcessInfo.processInfo.environment["SWITCHBOARD_STATE"] == nil, !already,
              let names = try? fm.contentsOfDirectory(atPath: old), names.contains(where: { $0.hasSuffix(".md") }) else { return }
        try? fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        for f in names where f.hasSuffix(".md") || f == "order.json" { try? fm.copyItem(atPath: old + "/" + f, toPath: new + "/" + f) }
        dlog("notes moved to ~/Notes (\(names.filter { $0.hasSuffix(".md") }.count) files); the old folder is kept")
    }
    static var dir: String {
        let chosen = defaults.string(forKey: folderKey)
        let d = (chosen?.isEmpty == false ? chosen! : defaultDir)
        // Rows read a note's path on every redraw: a stat, not a create, when it exists.
        // Only the default folder is ever created: a folder the owner chose that has gone
        // missing (an unplugged drive) must not be quietly replaced by an empty one.
        if d == defaultDir && !FileManager.default.fileExists(atPath: d) {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        return d
    }
    /// A sentence when the folder chosen in Settings is not there, else nil.
    static var missingFolder: String? {
        let d = dir
        guard d != defaultDir, !FileManager.default.fileExists(atPath: d) else { return nil }
        return "The notes folder \(abbreviateHome(d)) is missing. Is its drive connected? Pick another folder in Settings."
    }
    /// The saved order lives beside the default notes, but never inside a
    /// folder of the owner's own that was chosen in Settings.
    fileprivate static var orderPath: String {
        let d = dir
        guard d != defaultDir else { return d + "/order.json" }
        return AppPaths.stateDir + "/notes-order" + d.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    // ── Reading and writing the files ───────────────────────────────────────

    /// Reads the folder off the main thread, for the panel and at launch; a
    /// big chosen folder then never makes the panel stutter as it opens.
    func loadInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            let read = Self.readAll()
            DispatchQueue.main.async { self.apply(read) }
        }
    }

    func load() { apply(Self.readAll()) }

    /// Take a finished read; a problem with the folder shows as the tab's error line.
    private func apply(_ r: (notes: [Note], problem: String?)) {
        notes = r.notes
        loaded = true
        migrateOrderIfNeeded()
        loadTrash()
        // A read problem clears itself when the next read is clean (a drive plugged back in).
        if let p = r.problem { readProblem = p; error = p }
        else if let old = readProblem { readProblem = nil; if error == old { error = nil } }
    }
    private var readProblem: String?
    private static let readProblemTag = "Notes could not be read: "

    private static func readAll() -> (notes: [Note], problem: String?) {
        if let gone = missingFolder { return ([], gone) }
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: Self.dir) } catch {
            return ([], readProblemTag + "the folder could not be listed (\(error.localizedDescription)).")
        }
        let files = names.filter { $0.hasSuffix(".md") }
        var skipped = 0
        let read = files.compactMap { f -> Note? in
            guard let text = try? String(contentsOfFile: Self.dir + "/" + f, encoding: .utf8) else { skipped += 1; return nil }
            return Self.parse(id: String(f.dropLast(3)), text)
        }
        let problem = skipped == 0 ? nil : readProblemTag + (skipped == 1 ? "1 file is not readable text." : "\(skipped) files are not readable text.")
        return (NoteOrder.sorted(read), problem)
    }

    // ── The shared order ────────────────────────────────────────────────────

    /// The row being dragged; its new place is written once, when the drop ends.
    private var dragging: String?

    /// Re-sorts after any change, so a pin, a new note or a moved one lands where the one comparator puts it.
    private func resort() { notes = NoteOrder.sorted(notes) }

    /// Moves a note while it is dragged. A drag stays inside its pin group: a row cannot be dropped across the line.
    func move(_ dragged: String, to target: String) {
        guard let d = notes.first(where: { $0.id == dragged }), let t = notes.first(where: { $0.id == target }), d.pinned == t.pinned else { return }
        dragging = dragged
        notes = applyOrder(notes, reordered(notes.map(\.id), moving: dragged, to: target))
    }

    /// The drop: writes one `pos` into the dragged note's file, placed under the row now above it.
    /// `visible` is the ids on screen in order, so a search or colour filter uses the neighbours the owner sees.
    func commitMove(visible: [String]) {
        guard let d = dragging else { return }
        dragging = nil
        guard let m = notes.first(where: { $0.id == d }) else { return }
        // nothing to write when the drag ended where it began
        let persisted = NoteOrder.sorted(notes).map(\.id).filter(visible.contains)
        guard persisted != visible, let at = visible.firstIndex(of: d) else { resort(); return }
        var anchor: String?
        if at > 0, let above = notes.first(where: { $0.id == visible[at - 1] }), above.pinned == m.pinned { anchor = above.id }
        arrange(m.id, after: anchor)
    }

    /// Gives a note the place right under `anchor` (nil: top of its pin group). A group nobody has arranged
    /// yet gets keys once, one `pos` line per note, so the order it shows today is kept.
    func arrange(_ id: String, after anchor: String?) {
        guard let m = notes.first(where: { $0.id == id }) else { return }
        func others() -> [Note] { NoteOrder.sorted(notes).filter { $0.pinned == m.pinned && $0.id != id } }
        var group = others()
        let loose = group.filter { $0.pos == nil }
        let anchorNote = group.first { $0.id == anchor }
        if !loose.isEmpty, anchorNote == nil || anchorNote?.pos == nil {
            let below = group.first { NotePos.usable($0.pos) }?.pos
            for (n, key) in zip(loose, NotePos.fresh(loose.count, below: below)) { setPos(n.id, key) }
            group = others()
        }
        let at = anchor.flatMap { a in group.firstIndex { $0.id == a } } ?? -1
        let lower = group.prefix(at + 1).last { NotePos.usable($0.pos) }?.pos ?? ""
        let upper = group.dropFirst(at + 1).first { NotePos.usable($0.pos) }?.pos
        setPos(id, NotePos.between(lower, upper))
        resort()
        NotesSync.shared.commit("move")
    }

    /// Writes a note's `pos` only; a reorder is not an edit, so the file keeps its time.
    private func setPos(_ id: String, _ pos: String) {
        guard var n = notes.first(where: { $0.id == id }) else { return }
        let keep = n.modified
        n.pos = pos
        guard write(n) else { return }
        if let t = keep { try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: n.path) }
        if let i = notes.firstIndex(where: { $0.id == id }) { notes[i] = n }
    }

    /// The old `order.json` becomes `pos` lines once: the notes it names get well-spread keys in its order,
    /// the file is renamed (never deleted) and the change is one commit.
    private func migrateOrderIfNeeded() {
        let fm = FileManager.default
        let path = Self.orderPath
        guard fm.fileExists(atPath: path), Self.missingFolder == nil else { return }
        let saved = fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let named = applyOrder(notes.sorted { $0.created > $1.created }, saved).filter { saved.contains($0.id) }
        for (n, key) in zip(named, NotePos.spread(named.count)) { setPos(n.id, key) }
        var aside = path + ".migrated"
        if fm.fileExists(atPath: aside) { aside += "-" + String(Int(Date().timeIntervalSince1970)) }
        try? fm.moveItem(atPath: path, toPath: aside)
        resort()
        if !named.isEmpty { NotesSync.shared.commit("order: migrate") }
        dlog("notes order: \(named.count) notes moved from order.json to pos")
    }

    /// Live notes in the owner's order, then expired ones.
    var live: [Note] { notes.filter { !$0.expired } }
    var expired: [Note] { notes.filter(\.expired) }

    @discardableResult
    func add(_ text: String) -> Note? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: "\n")
        return add(title: lines[0], body: lines.dropFirst().joined(separator: "\n"))
    }

    /// Saves a new note from a title and a body, either of which may be empty
    /// but not both; the same note twice is saved once.
    @discardableResult
    func add(title rawTitle: String, body rawBody: String, color: String? = nil, url rawURL: String = "") -> Note? {
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = rawURL.trimmingCharacters(in: .whitespaces)
        guard InputRules.canSave(title: title, body: body, url: url) else { return nil }
        // Enter on a note already saved does not make a second copy.
        if let same = notes.first(where: { $0.title == title && $0.body == body && ($0.url ?? "") == url }) { return same }
        var n = Note(id: newID(), title: title, body: body, tags: [], created: Self.now())
        n.color = color.flatMap(NotePalette.shared.writable)
        n.url = url.isEmpty ? nil : url
        guard write(n) else { return nil }
        // no pos: a new note is never-arranged, so the comparator puts it on top of its pin group
        notes.append(n)
        resort()
        return n
    }

    /// Now in whole seconds: the file keeps no more, and a note must sort the same before and after a reload.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    private func newID() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        var id = f.string(from: Date())
        while notes.contains(where: { $0.id == id }) { id += "x" }
        return id
    }

    /// A second note with the same words, tags, colour and link, placed under the first.
    /// It is never pinned and carries no reminder or expiry, so nothing fires twice.
    @discardableResult
    func duplicate(_ n: Note) -> Note? {
        var c = Note(id: newID(), title: n.title.isEmpty ? "" : n.title + " copy", body: n.body, tags: n.tags, created: Self.now())
        c.color = n.color
        c.url = n.url
        guard write(c) else { return nil }
        notes.append(c)
        resort()
        // the copy is never pinned; under an unpinned original it takes the place right below it
        if !n.pinned { arrange(c.id, after: n.id) }
        return notes.first { $0.id == c.id } ?? c
    }

    /// Save a changed note; its reminder follows only a change to when, how
    /// often or what it says, so typing in the body does not touch Reminders.
    func update(_ n: Note) {
        var n = n
        let old = notes.first { $0.id == n.id }
        // an editor holding an older copy must not undo a move that arrived since
        if let old { n.pos = old.pos }
        var problem: String?
        if old?.remindAt != n.remindAt || old?.remindRepeat != n.remindRepeat || old?.title != n.title { problem = syncReminder(&n) }
        // pinning or tagging is not editing: keep the file's time, which the hover card reads as "last edited"
        let keepTime = old.map { $0.title == n.title && $0.body == n.body && $0.tags == n.tags } == true ? old?.modified : nil
        guard write(n) else { return }
        if let t = keepTime { try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: n.path) }
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n; resort() }
        // After write, which clears the error line on success.
        if let p = problem { error = p }
    }

    func delete(_ n: Note) {
        var gone = n
        gone.remindAt = nil
        let reminderProblem = syncReminder(&gone)
        // into .trash beside the notes (bfb does the same), so Recently deleted can bring it back
        do { try moveToTrash(n) } catch {
            self.error = "\(n.title) could not be removed: \(error.localizedDescription)"; return
        }
        notes.removeAll { $0.id == n.id }
        loadTrash()
        NotesSync.shared.commit("delete")
        // The note is gone either way; a reminder left behind would fire for nothing.
        if let p = reminderProblem { self.error = "The note was deleted, but its reminder was not removed: \(p)" }
    }

    // ── Recently deleted ────────────────────────────────────────────────────

    /// A deleted note waiting in `.trash`, with when it went there.
    struct Trashed: Identifiable {
        let file: String
        let note: Note
        let deleted: Date
        var id: String { file }
    }
    @Published private(set) var trashed: [Trashed] = []
    static var trashDir: String { dir + "/.trash" }

    private func moveToTrash(_ n: Note) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.trashDir, withIntermediateDirectories: true)
        var name = n.id + ".md"
        while fm.fileExists(atPath: Self.trashDir + "/" + name) { name = n.id + "-" + String(Int(Date().timeIntervalSince1970)) + String(Int.random(in: 0..<100)) + ".md" }
        try fm.moveItem(atPath: n.path, toPath: Self.trashDir + "/" + name)
    }

    /// Reads `.trash`, newest deletion first; a folder that is not there is an empty list.
    func loadTrash() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Self.trashDir)) ?? []).filter { $0.hasSuffix(".md") }
        trashed = names.compactMap { f -> Trashed? in
            let path = Self.trashDir + "/" + f
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), let n = Self.parse(id: String(f.dropLast(3)), text) else { return nil }
            let url = URL(fileURLWithPath: path)
            let when = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                ?? (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()
            return Trashed(file: f, note: n, deleted: when)
        }.sorted { $0.deleted > $1.deleted }
    }

    /// Puts a deleted note back in the list, under a new name if its own is taken. Its reminder
    /// was removed when it was deleted, so it comes back without one.
    @discardableResult
    func restore(_ t: Trashed) -> Note? {
        let fm = FileManager.default
        var id = t.note.id
        while fm.fileExists(atPath: Self.dir + "/" + id + ".md") { id += "x" }
        do { try fm.moveItem(atPath: Self.trashDir + "/" + t.file, toPath: Self.dir + "/" + id + ".md") } catch {
            self.error = "\(t.note.heading) could not be brought back: \(error.localizedDescription)"; return nil
        }
        load()
        guard var n = notes.first(where: { $0.id == id }) else { return nil }
        if n.remindAt != nil || n.reminderID != nil {
            n.remindAt = nil; n.reminderID = nil
            update(n)
        } else {
            NotesSync.shared.commit("restore")
        }
        return notes.first { $0.id == id }
    }

    /// Removes one deleted note for good, into the macOS Trash so even that can be undone.
    func purge(_ t: Trashed) {
        let url = URL(fileURLWithPath: Self.trashDir + "/" + t.file)
        // a probe never fills the owner's macOS Trash
        do { if Self.probing { try FileManager.default.removeItem(at: url) } else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } } catch {
            self.error = "\(t.note.heading) could not be removed: \(error.localizedDescription)"
        }
        loadTrash()
    }

    private func write(_ n: Note) -> Bool {
        if let gone = Self.missingFolder { error = gone; return false }
        do {
            try Self.render(n).write(toFile: n.path, atomically: true, encoding: .utf8)
            error = nil
            NotesSync.shared.commit("save")
            return true
        } catch {
            self.error = "the note could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    // ── The file format: a small frontmatter block, then the body ───────────

    private static let iso = ISO8601DateFormatter()

    /// Strings are written JSON-quoted, so a colon or quote in a title survives.
    static func render(_ n: Note) -> String {
        func q(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        var lines = ["---", "title: " + q(n.title)]
        // a hand-written note with no created line stays without one (the Pi leaves it absent too)
        if n.created != Date.distantPast { lines.append("created: " + iso.string(from: n.created)) }
        if !n.tags.isEmpty { lines.append("tags: " + q(n.tags.joined(separator: ", "))) }
        if let e = n.expires { lines.append("expires: " + iso.string(from: e)) }
        if let r = n.remindAt {
            lines.append("remind_at: " + iso.string(from: r))
            if n.remindRepeat != .never { lines.append("remind_repeat: " + n.remindRepeat.rawValue) }
        }
        if let id = n.reminderID, !id.isEmpty { lines.append("reminder_id: " + q(id)) }
        if n.pinned { lines.append("pinned: true") }
        if let c = n.color { lines.append("color: " + c) }
        if let a = n.agent { lines.append("agent: " + q(a)) }
        if let s = n.source { lines.append("source: " + q(s)) }
        if let u = n.url { lines.append("url: " + q(u)) }
        // bare, so a reader that sees `no` or `1e5` still gets the exact text back
        if let p = n.pos, !p.isEmpty { lines.append("pos: " + p) }
        lines += n.extra
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + n.body + (n.body.isEmpty ? "" : "\n")
    }

    static func parse(id: String, _ raw: String) -> Note? {
        // a file saved on Windows or by some editors ends lines with \r\n; the Pi and bfb read it as \n
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [String: String] = [:]
        var extra: [String] = []
        let known: Set<String> = ["title", "created", "tags", "expires", "remind_at", "remind_repeat", "reminder_id",
                                  "pinned", "color", "agent", "source", "url", "pos"]
        var body = text
        // from offset 3, so an empty block ("---" then "---") closes too
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let start = text.index(text.startIndex, offsetBy: 4)
            for line in (start < end.lowerBound ? text[start..<end.lowerBound] : "").components(separatedBy: "\n") {
                guard let c = line.firstIndex(of: ":") else {
                    // a non-blank line with no colon (a YAML list item from another editor) is kept in place
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { extra.append(line) }
                    continue
                }
                if !known.contains(String(line[..<c]).trimmingCharacters(in: .whitespaces)) { extra.append(line); continue }
                var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), let d = try? JSONSerialization.jsonObject(with: Data("[\(v)]".utf8)) as? [String], let s = d.first { v = s }
                // YAML single quotes, as other editors write them: '' is a literal quote
                else if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                fields[String(line[..<c]).trimmingCharacters(in: .whitespaces)] = v
            }
            body = String(text[end.upperBound...])
        }
        if let t = fields["title"] { fields["title"] = t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : t.trimmingCharacters(in: .whitespaces) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A file written by hand has no title field: its first line is the
        // title (a markdown heading loses its #) and the rest stays the body.
        var title = fields["title"] ?? id
        if fields["title"] == nil, !body.isEmpty {
            let lines = body.components(separatedBy: "\n")
            title = lines[0].drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Note(id: id, title: title, body: body,
                    tags: (fields["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    created: fields["created"].flatMap(iso.date) ?? Date.distantPast,
                    expires: fields["expires"].flatMap(iso.date),
                    remindAt: fields["remind_at"].flatMap(iso.date),
                    remindRepeat: fields["remind_repeat"].flatMap(Note.Repeat.init) ?? .never,
                    reminderID: fields["reminder_id"],
                    pinned: fields["pinned"] == "true",
                    color: fields["color"].flatMap(noteColorName),
                    agent: fields["agent"].flatMap { $0.isEmpty ? nil : $0 },
                    source: fields["source"].flatMap { $0.isEmpty ? nil : $0 },
                    url: fields["url"].flatMap { $0.isEmpty ? nil : $0 },
                    pos: fields["pos"].flatMap { $0.isEmpty ? nil : $0 }, extra: extra)
    }

    // ── Reminders ───────────────────────────────────────────────────────────

    private let events = EKEventStore()
    /// Set by the headless probe so it never touches the real Reminders.
    static var remindersOff = false
    /// macOS Reminders, or a stand-in the probe uses to play the permission dialog.
    lazy var reminders: ReminderBackend = .system(events)

    /// Make Reminders match the note: add, move or remove its one reminder.
    /// Access is asked the first time a reminder is set, never before.
    /// Returns what went wrong in plain words, or nil.
    private func syncReminder(_ n: inout Note) -> String? {
        guard !Self.remindersOff else { return nil }
        guard n.remindAt != nil else {
            guard let id = n.reminderID else { return nil }
            // Keep the id when removal fails, so the reminder can still be found later.
            if let why = reminders.remove(id) { return "the reminder could not be removed: \(why)" }
            n.reminderID = nil
            return nil
        }
        switch reminders.status() {
        case .fullAccess, .authorized, .writeOnly: break
        case .notDetermined:
            // The note is saved now and the reminder follows the answer, made
            // from the note as it is then: it may have been edited meanwhile.
            let id = n.id
            reminders.requestAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard granted else { self.error = "Reminders access was not given, so the reminder was not set."; return }
                    guard var now = self.notes.first(where: { $0.id == id }), now.remindAt != nil else { return }
                    let problem = self.syncReminder(&now)
                    guard self.write(now) else { return }
                    if let i = self.notes.firstIndex(where: { $0.id == id }) { self.notes[i] = now }
                    if let p = problem { self.error = p }
                }
            }
            return nil
        default:
            return "Switchboard may not add reminders. Allow it in System Settings > Privacy & Security > Reminders."
        }
        do {
            n.reminderID = try reminders.save(n)
            return nil
        } catch {
            return "the reminder could not be saved: \(error.localizedDescription)"
        }
    }
}

/// The three things notes need from Reminders.
struct ReminderBackend {
    var status: () -> EKAuthorizationStatus
    var requestAccess: (@escaping (Bool) -> Void) -> Void
    /// Adds or moves the note's one reminder; returns its identifier.
    var save: (Note) throws -> String
    /// Removes a reminder; returns why it could not, or nil (a reminder already gone counts as removed).
    var remove: (String) -> String?

    static func system(_ events: EKEventStore) -> ReminderBackend {
        func existing(_ id: String?) -> EKReminder? { id.flatMap { events.calendarItem(withIdentifier: $0) as? EKReminder } }
        return ReminderBackend(
            status: { EKEventStore.authorizationStatus(for: .reminder) },
            requestAccess: { done in events.requestFullAccessToReminders { granted, _ in done(granted) } },
            save: { n in
                let r = existing(n.reminderID) ?? EKReminder(eventStore: events)
                r.title = n.title
                r.notes = (n.body.isEmpty ? "" : n.body + "\n\n") + n.path
                if r.calendar == nil { r.calendar = events.defaultCalendarForNewReminders() }
                let at = n.remindAt ?? Date()
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                r.alarms?.forEach { r.removeAlarm($0) }
                r.addAlarm(EKAlarm(absoluteDate: at))
                r.recurrenceRules?.forEach { r.removeRecurrenceRule($0) }
                let freq: EKRecurrenceFrequency? = [.daily: .daily, .weekly: .weekly, .monthly: .monthly][n.remindRepeat]
                if let f = freq { r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f, interval: 1, end: nil)) }
                try events.save(r, commit: true)
                return r.calendarItemIdentifier
            },
            remove: { id in
                guard let r = existing(id) else { return nil }
                do { try events.remove(r, commit: true); return nil } catch { return error.localizedDescription }
            })
    }
}
