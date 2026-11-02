// NotesFinishProbe.swift
// Headless checks for the last round on the notes surface: the inbox for a big merge and for Done on an arrival the list
// has not read, the one-time move of older pins, a tag rename being one commit, a phone's reminder handle, the chord
// being held by another app, the editor's keys acting on their own text view, the tag and title limits, and the shared
// timer templates in a reminder's picker. Scratch folder with its own repository; nothing here touches the owner's notes.

import AppKit
import Carbon.HIToolbox
import Foundation

func probeFinish() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "sb-finish-\(getpid())"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let defaults = NotesStore.defaults
    let oldFolder = defaults.string(forKey: NotesStore.folderKey)
    defaults.set(root + "/notes", forKey: NotesStore.folderKey)
    defaults.removeObject(forKey: NotesSync.remoteKey)
    defaults.removeObject(forKey: SavedStore.migratedKey)
    defer {
        if let f = oldFolder { defaults.set(f, forKey: NotesStore.folderKey) } else { defaults.removeObject(forKey: NotesStore.folderKey) }
        defaults.removeObject(forKey: SavedStore.migratedKey)
    }
    @discardableResult func g(_ a: String...) -> GitResult { NotesSync.runGit(a, cwd: root + "/notes") }
    func read(_ f: String) -> String { (try? String(contentsOfFile: root + "/notes/" + f, encoding: .utf8)) ?? "" }
    func put(_ f: String, _ t: String) {
        try? fm.createDirectory(atPath: (root + "/notes/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? t.write(toFile: root + "/notes/" + f, atomically: true, encoding: .utf8)
    }
    func commits() -> Int { Int(g("rev-list", "--count", "HEAD").out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    func waitForSync(_ sync: NotesSync) {
        let until = Date().addingTimeInterval(10)
        while sync.syncing, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    NotesStore.remindersOff = true
    let sync = NotesSync.shared
    _ = sync.ensureRepo()
    g("config", "user.name", "T"); g("config", "user.email", "t@t")
    let oldDeliver = NotesInbox.deliver
    var told = 0
    NotesInbox.deliver = { _, _, _ in told += 1 }
    defer { NotesInbox.deliver = oldDeliver }

    // S16: Done on an arrival before the list has read it still writes the note away
    try? fm.removeItem(atPath: NotesInbox.path)
    let inbox = NotesInbox()
    inbox.reload()
    put("20261101-120000-aaaa.md", "---\ntitle: \"Phone note\"\n---\nwords from the phone\n")
    sync.commitNow("save")
    inbox.ingest(ids: ["20261101-120000-aaaa"], dir: root + "/notes")
    let cold = NotesStore()
    inbox.done("20261101-120000-aaaa", notes: cold)
    check("Done on an arrival the list has not read yet still puts the note away, and keeps its words",
          read("20261101-120000-aaaa.md").contains("expires:") && read("20261101-120000-aaaa.md").contains("words from the phone") && inbox.waiting().isEmpty,
          read("20261101-120000-aaaa.md"))

    // S17: a big merge leaves one line on the Notes tab and agents' notes stay in their lane
    try? fm.removeItem(atPath: NotesInbox.path)
    let big = NotesInbox()
    big.reload()
    var ids: [String] = []
    for i in 0..<35 {
        let id = String(format: "20261101-13%02d00-bbbb", i)
        put(id + ".md", "---\ntitle: \"Arrived \(i)\"\n---\nbody \(i)\n"); ids.append(id)
    }
    for i in 0..<2 {
        let id = String(format: "20261101-14%02d00-cccc", i)
        put(id + ".md", "---\ntitle: \"Agent \(i)\"\nagent: \"claude\"\n---\nfrom an agent\n"); ids.append(id)
    }
    told = 0
    big.ingest(ids: ids, dir: root + "/notes")
    check("a merge of 35 notes leaves one line in the inbox saying how many came", big.waiting().count == 1 && big.waiting().first?.isBulk == true
          && big.waiting().first?.count == 35 && big.waiting().first?.title == "35 notes arrived at once", "\(big.waiting().map(\.title))")
    check("the agents' two notes in that merge still go to the lane, not the owner's list", big.lane().count == 2 && big.agentLaneIDs.count == 2, "\(big.lane().map(\.id))")
    check("the owner is told once, with the count", told == 1, "\(told)")
    let badge = NotesWaiting.badges(inbox: big, notes: [], ringer: ReminderRinger()).first { $0.id == "notes-inbox" }
    check("the waiting badge counts the notes, not the one line", badge?.text == "35 in the inbox", badge?.text ?? "none")
    big.prune(dir: root + "/notes")
    check("the line is not taken for a note whose file is gone", big.waiting().count == 1)
    let before = read(ids[0] + ".md")
    if let line = big.waiting().first { big.done(line.id) }
    check("clearing the line touches no note", big.waiting().isEmpty && read(ids[0] + ".md") == before && big.lane().count == 2)
    let small = NotesInbox()
    try? fm.removeItem(atPath: NotesInbox.path)
    small.reload()
    small.ingest(ids: Array(ids.prefix(5)), dir: root + "/notes")
    check("a few arrivals are still listed one by one", small.waiting().count == 5 && !small.waiting().contains { $0.isBulk })

    // S19 and S20: the one-time move leaves a reminder where it rings, shows no false deletion, and keeps its own commit
    for f in ((try? fm.contentsOfDirectory(atPath: root + "/notes")) ?? []) where f.hasSuffix(".md") { try? fm.removeItem(atPath: root + "/notes/" + f) }
    sync.commitNow("save")
    defaults.removeObject(forKey: SavedStore.migratedKey)
    put("pinr.md", "---\ntitle: \"Ring pin\"\nurl: \"https://example.com/ring\"\nremind_at: 2027-12-01T09:00:00Z\n---\n")
    // written loosely, so the move rewrites nearly every line and git reads it as a deletion plus a new file
    put("tiny.md", "---\ntitle:   A\nurl:   https://example.com/tiny\ntags: [pin]\n---\n")
    put("typing.md", "---\ntitle: \"Typing\"\n---\nwords still waiting for their commit\n")
    sync.commitNow("save")
    put("typing.md", "---\ntitle: \"Typing\"\n---\nwords still waiting for their commit, edited\n")
    sync.commit("typing")
    let moved = SavedStore().migrateOldPinsIfNeeded()
    check("a pin with a reminder stays a note, so it still rings", moved == 1 && fm.fileExists(atPath: root + "/notes/pinr.md") && !fm.fileExists(atPath: root + "/notes/tiny.md"), "\(moved)")
    let subjects = g("log", "-3", "--format=%s").out.split(separator: "\n").map(String.init)
    check("the move is one commit under its own name, after the typing that was waiting", subjects.prefix(2) == ["saved: move 1 older pin", "typing"], "\(subjects)")
    let sawDelete = g("log", "-1", "--diff-filter=D", "--name-only", "--format=").out.contains("tiny.md")
    let hist = NotesStore.deletedInHistory()
    check("a moved pin that git reads as a deletion is not listed under Recently deleted", sawDelete && !hist.contains { $0.note.id == "tiny" },
          "git read a deletion: \(sawDelete); \(hist.map(\.note.id))")

    // commitAlone keeps its own name even when a sync round starts while it writes
    put("racer.md", "---\ntitle: \"Racer\"\n---\nx\n")
    sync.commitNow("save")
    sync.commitAlone("moved on its own") {
        try? "---\ntitle: \"Racer\"\n---\nchanged under the move\n".write(toFile: root + "/notes/racer.md", atomically: true, encoding: .utf8)
        sync.sync(force: false)
    }
    waitForSync(sync)
    check("a change committed on its own keeps its name although a sync round began during the write", g("log", "--format=%s", "--", "racer.md").out.hasPrefix("moved on its own"),
          g("log", "--format=%s", "-3").out)

    // S21: renaming a tag is one commit even when a sync round commits right after the first file changed
    let s = NotesStore()
    s.load()
    for i in 0..<6 { var n = s.add(title: "Tagged \(i)", body: "b\(i)")!; n.tags = ["oldtag"]; s.update(n) }
    sync.commitNow("save")
    let c0 = commits()
    var fired = false
    TagRename.afterPatch = {
        guard !fired else { return }
        fired = true
        // the sync round's commit, started from another thread at this exact moment inside the batch
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { sync.commitNow("race"); done.signal() }
        done.wait()
    }
    let changed = TagRename.run("oldtag", to: "newtag", notes: s, saved: SavedStore())
    TagRename.afterPatch = nil
    check("the rename queues its commit and does not make it on the caller's thread, so the panel never waits behind a sync round", commits() == c0, "commits +\(commits() - c0)")
    sync.commitNow("save")
    check("a rename of 6 notes lands as one commit although a sync round tried to commit after the first", fired && changed == 6 && commits() - c0 == 1, "changed \(changed), commits +\(commits() - c0)")
    check("every note carries the new tag in that commit", g("diff", "--name-only", "HEAD~1", "HEAD").out.split(separator: "\n").count == 6, g("diff", "--name-only", "HEAD~1", "HEAD").out)

    // S22: a reminder the phone owns keeps the phone's own handle when the Mac edits the note
    NotesStore.remindersOff = false
    let rs = NotesStore()
    var removed: [String] = []
    rs.reminders = ReminderBackend(status: { .fullAccess }, requestAccess: { $0(true) }, save: { _ in "mac-1" },
                                   remove: { removed.append($0); return nil }, owns: { $0 == "mac-1" })
    var phoneNote = rs.add(title: "Phone rings", body: "x")!
    phoneNote.remindAt = Date().addingTimeInterval(3600); phoneNote.remindOn = "phone"; phoneNote.reminderID = "phone-handle"
    rs.update(phoneNote)
    check("the Mac editing a phone-owned reminder leaves the phone's handle in the note", rs.notes.first { $0.id == phoneNote.id }?.reminderID == "phone-handle"
          && read(phoneNote.id + ".md").contains("phone-handle"), rs.notes.first { $0.id == phoneNote.id }?.reminderID ?? "nil")
    var handedOver = rs.add(title: "Was the Mac's", body: "y")!
    handedOver.remindAt = Date().addingTimeInterval(3600); handedOver.remindOn = "phone"; handedOver.reminderID = "mac-1"
    rs.update(handedOver)
    check("an item this Mac made is let go when the reminder moves to the phone", rs.notes.first { $0.id == handedOver.id }?.reminderID == nil && removed.contains("mac-1"), "\(removed)")
    NotesStore.remindersOff = true

    // S23: the cursor at the end of a body counts the way the text view does
    check("a body with emoji puts the cursor at its true end", PolicyStatusController.endCaret(of: "hi 👍🏽 ok") == ("hi 👍🏽 ok" as NSString).length, "\(PolicyStatusController.endCaret(of: "hi 👍🏽 ok"))")

    // S24: a chord another app already holds is reported, not just logged
    var other: EventHotKeyRef?
    let held = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey | shiftKey), EventHotKeyID(signature: OSType(0x4F544852), id: 77), GetApplicationEventTarget(), 0, &other)
    if held != noErr {
        lines.append("skip chord clash: ⌥⇧N could not be taken for the test (\(held)), so it is already held")
    } else {
        let keep = AppDefaults.store.object(forKey: HotKeys.captureKey)
        AppDefaults.store.set(true, forKey: HotKeys.captureKey)
        HotKeys.shared.reloadChords()
        check("a chord macOS refuses is listed by name", HotKeys.shared.failed == ["⌥⇧N"], "\(HotKeys.shared.failed)")
        check("and Settings says it is not working instead of on", HotKeys.captureNote(on: true, failed: HotKeys.shared.failed) == "not working: another app holds ⌥⇧N")
        if let o = other { UnregisterEventHotKey(o) }
        HotKeys.shared.reloadChords()
        check("once the other app lets go, it works and the note says on", HotKeys.shared.failed.isEmpty && HotKeys.captureNote(on: true, failed: HotKeys.shared.failed).hasPrefix("on"), "\(HotKeys.shared.failed)")
        AppDefaults.store.set(false, forKey: HotKeys.captureKey)
        HotKeys.shared.reloadChords()
        if let k = keep { AppDefaults.store.set(k, forKey: HotKeys.captureKey) } else { AppDefaults.store.removeObject(forKey: HotKeys.captureKey) }
        HotKeys.shared.reloadChords()
    }

    // the same for ⌥Space, the way in from anywhere
    HotKeys.shared.releaseChords()
    var otherLeader: EventHotKeyRef?
    let heldLeader = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x4F544852), id: 78), GetApplicationEventTarget(), 0, &otherLeader)
    // either this probe holds ⌥Space, or something else on this Mac already does; either way macOS refuses the app
    HotKeys.shared.reloadChords()
    check("⌥Space refused by macOS is listed by name", HotKeys.shared.failed.contains("⌥Space"), "\(HotKeys.shared.failed)")
    check("and the keyboard list in Settings says it is not working", HotKeys.leaderNote(failed: HotKeys.shared.failed).hasPrefix("not working: another app holds ⌥Space")
          && SettingsTabView.keyGroups.first?.keys.first?.1.hasPrefix("not working") == true, SettingsTabView.keyGroups.first?.keys.first?.1 ?? "none")
    if heldLeader == noErr, let o = otherLeader {
        UnregisterEventHotKey(o)
        HotKeys.shared.reloadChords()
        check("once it is free the list reads as before", !HotKeys.shared.failed.contains("⌥Space") && SettingsTabView.keyGroups.first?.keys.first?.1 == "Open; again for letters; again to close")
    } else {
        lines.append("note leader: ⌥Space was already held by another program here (\(heldLeader)), so the refusal above is that program's; the release was not tried")
    }

    // comparing the other app's version with the words typed here
    let cmp = NoteMerge.diff(mine: ["T", "one", "two mine", "three", "four", "five", "six", "seven"], theirs: ["T", "one", "two theirs", "three", "four", "five", "six", "seven", "added"], context: 1)
    check("a comparison keeps the changed lines and one line around each, theirs before mine",
          cmp == [.init(kind: .gap, text: "…"), .init(kind: .same, text: "one"), .init(kind: .theirs, text: "two theirs"), .init(kind: .mine, text: "two mine"), .init(kind: .same, text: "three"),
                  .init(kind: .gap, text: "…"), .init(kind: .same, text: "seven"), .init(kind: .theirs, text: "added")], "\(cmp.map { "\($0.kind) \($0.text)" })")
    check("two copies with the same lines compare as only a gap", NoteMerge.diff(mine: ["a", "b"], theirs: ["a", "b"]).allSatisfy { $0.kind == .gap })
    check("an empty side is all of the other", NoteMerge.diff(mine: [], theirs: ["x"]) == [.init(kind: .theirs, text: "x")])

    // the editor's keys act on their own text view, with no window, no key window and no front app
    func key(_ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }
    func editor(_ text: String, _ sel: NSRange) -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        tv.isRichText = false
        tv.isEditable = true
        tv.string = text
        tv.setSelectedRange(sel)
        return tv
    }
    let b = editor("from one and two", NSRange(location: 5, length: 3))
    b.keyDown(with: key(kVK_ANSI_B, "b", .command))
    check("⌘B wraps the word in bold in the view the key came to, with no window at all", b.string == "from **one** and two" && b.selectedRange() == NSRange(location: 7, length: 3), b.string)
    let nf = editor("x", NSRange(location: 0, length: 1))
    nf.keyDown(with: key(kVK_ANSI_I, "i", .command))
    check("⌘I and the other formats work the same", nf.string == "_x_")
    let sx = editor("old", NSRange(location: 0, length: 3))
    sx.keyDown(with: key(kVK_ANSI_X, "x", [.command, .shift]))
    check("⌘⇧X strikes through", sx.string == "~~old~~", sx.string)
    let hh = editor("title", NSRange(location: 0, length: 0))
    hh.keyDown(with: key(kVK_ANSI_H, "h", [.command, .shift])); hh.keyDown(with: key(kVK_ANSI_H, "h", [.command, .shift]))
    check("⌘⇧H adds a heading level each press", hh.string == "## title", hh.string)
    let kk = editor("see docs", NSRange(location: 4, length: 4))
    kk.keyDown(with: key(kVK_ANSI_K, "k", .command))
    check("⌘K makes a link around the selection", kk.string.hasPrefix("see [docs](") && kk.string.hasSuffix(")"), kk.string)
    let qq = editor("a\nb", NSRange(location: 0, length: 3))
    qq.keyDown(with: key(kVK_ANSI_Period, ">", [.command, .shift]))
    check("⌘⇧. quotes the lines", qq.string == "> a\n> b", qq.string)
    let ol = editor("a\nb", NSRange(location: 0, length: 3))
    ol.keyDown(with: key(kVK_ANSI_7, "&", [.command, .shift]))
    check("⌘⇧7 numbers the lines", ol.string == "1. a\n2. b", ol.string)
    var saved = 0, stepped = 0, deleted = 0
    let hooks = editor("x", NSRange(location: 1, length: 0))
    hooks.onSave = { saved += 1 }; hooks.onStep = { stepped += $0 }; hooks.onDelete = { deleted += 1 }
    hooks.keyDown(with: key(kVK_ANSI_S, "s", .command))
    hooks.keyDown(with: key(kVK_UpArrow, "\u{F700}", [.command, .option]))
    hooks.keyDown(with: key(kVK_DownArrow, "\u{F701}", [.command, .option])); hooks.keyDown(with: key(kVK_DownArrow, "\u{F701}", [.command, .option]))
    hooks.keyDown(with: key(kVK_Delete, "\u{7F}", [.command, .shift]))
    check("⌘S saves, ⌥⌘↑ and ⌥⌘↓ step to the neighbouring note, ⌘⇧⌫ deletes", saved == 1 && stepped == 1 && deleted == 1, "\(saved) \(stepped) \(deleted)")
    let tab = editor("a\nb", NSRange(location: 0, length: 3))
    tab.keyDown(with: key(kVK_Tab, "\t", []))
    check("Tab indents the selected lines", tab.string == "  a\n  b", tab.string)
    tab.keyDown(with: key(kVK_Tab, "\t", .shift))
    check("Shift-Tab takes it back", tab.string == "a\nb", tab.string)
    let ret = editor("- milk", NSRange(location: 6, length: 0))
    ret.keyDown(with: key(kVK_Return, "\r", []))
    check("Return at the end of a list item starts the next", ret.string == "- milk\n- " && ret.selectedRange().location == 9, ret.string)
    ret.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("a marker typed over the one Return put is folded into it", ret.string == "- milk\n- ", ret.string)
    let title = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
    title.isFieldEditor = true; title.isEditable = true; title.string = "t"; title.setSelectedRange(NSRange(location: 0, length: 1))
    title.keyDown(with: key(kVK_ANSI_B, "b", .command))
    check("the title line takes none of the body's formatting keys", title.string == "t", title.string)

    // the tag and title limits the extension and the phone keep
    check("a comma ends a tag, spaces stay inside one, repeats and empties are dropped",
          InputRules.addTags(typed: "work,  big  plan , ,work", to: ["x"]).tags == ["x", "work", "big plan"])
    check("a pin tag is refused with a reason and nothing is added", InputRules.addTags(typed: "ok, Pin", to: []).tags.isEmpty && InputRules.addTags(typed: "pin", to: []).problem?.contains("pin") == true)
    check("a tag over 32 characters is refused", InputRules.addTags(typed: String(repeating: "a", count: 33), to: []).problem == "A tag is at most 32 characters"
          && InputRules.addTags(typed: String(repeating: "a", count: 32), to: []).problem == nil)
    let twelve = (1...12).map { "t\($0)" }
    check("a thirteenth tag is refused", InputRules.addTags(typed: "more", to: twelve).problem == "A note keeps at most 12 tags" && InputRules.addTags(typed: "t1", to: twelve).problem == nil)
    check("a title is one line", InputRules.cleanTitle("a\n  b \n") == "a b")

    // F1: a long title loses no word; an untouched one is never cut
    let words = (1...60).map { "word\($0)" }
    let longTitle = words.joined(separator: " ")
    let cut = InputRules.settleTitle(old: "", new: longTitle, body: "the body")
    check("a title typed or pasted over 200 characters is cut at a word and the rest goes to the top of the body",
          cut.title.count <= 200 && !cut.title.hasSuffix(" ") && cut.body.hasSuffix("\n\nthe body")
          && (cut.title + " " + cut.body).split(whereSeparator: \.isWhitespace).map(String.init) == words + ["the", "body"], "\(cut.title.count): \(cut.title) | \(cut.body.prefix(40))")
    let run = InputRules.settleTitle(old: "x", new: String(repeating: "q", count: 330), body: "")
    check("an unbroken run is cut at 200 and the remainder is kept", run.title.count == 200 && run.body.count == 130)
    check("a title the owner did not touch is left as it is, however long", InputRules.settleTitle(old: longTitle, new: longTitle, body: "b") == (longTitle, "b"))
    let stored = NotesStore()
    stored.load()
    let added = stored.add(title: longTitle, body: "kept body")
    check("a long title saved through the store keeps every word between title and body", added.map { ($0.title + " " + $0.body).split(whereSeparator: \.isWhitespace).count } == words.count + 2
          && (added?.title.count ?? 999) <= 200, "\(added?.title.count ?? -1)")

    // F2: Keep mine puts the other app's version in the history before overwriting it
    var theirsNote = stored.add(title: "Shared", body: "base words")!
    sync.commitNow("save")
    try? "---\ntitle: \"Shared\"\n---\nwords the other app wrote\n".write(toFile: theirsNote.path, atomically: true, encoding: .utf8)
    theirsNote.body = "words typed here"
    stored.update(theirsNote, keepingOtherVersion: true)
    check("the other app's version is committed before Keep mine overwrites it", g("log", "-p", "--format=%s", "--", theirsNote.id + ".md").out.contains("+words the other app wrote")
          && read(theirsNote.id + ".md").contains("words typed here"), g("log", "--format=%s", "-4").out)

    // F3: while a clash waits, the words typed here are kept as a copy, once, and it goes when they are saved
    let copyID = stored.keepCopy(id: nil, title: "Shared", body: "typed 1", label: "typed here")
    let again = stored.keepCopy(id: copyID, title: "Shared", body: "typed 1 and 2", label: "typed here")
    check("a copy of the typed words is made once and then updated, not repeated",
          copyID != nil && again == copyID && stored.notes.filter { $0.title == "Shared (typed here)" }.count == 1
          && stored.notes.first { $0.id == copyID }?.body == "typed 1 and 2", "\(stored.notes.map(\.title))")

    // F4: what the other app changed besides words is carried into the draft
    var base4 = Note(id: "m", title: "T", body: "base", tags: ["a"], created: Date())
    base4.remindAt = Date(timeIntervalSince1970: 1_800_000_000)
    var mine4 = base4; mine4.body = "base mine"
    var theirs4 = base4; theirs4.body = "base theirs"; theirs4.remindAt = Date(timeIntervalSince1970: 1_800_100_000); theirs4.tags = ["a", "b"]
    theirs4.url = "https://example.com/x"; theirs4.color = "green"; theirs4.expires = Date(timeIntervalSince1970: 1_900_000_000)
    let carried = NoteMerge.carryFields(draft: mine4, base: base4, theirs: theirs4)
    check("a reminder, tags, link, colour and expiry changed by the other app come into the draft; the typed words stay",
          carried.body == "base mine" && carried.remindAt == theirs4.remindAt && carried.tags == ["a", "b"] && carried.url == theirs4.url
          && carried.color == "green" && carried.expires == theirs4.expires, "\(carried.remindAt as Any) \(carried.tags)")
    var mine4b = mine4; mine4b.remindAt = Date(timeIntervalSince1970: 1_800_200_000)
    check("a reminder moved on both sides: the later time wins",
          NoteMerge.carryFields(draft: mine4b, base: base4, theirs: theirs4).remindAt == mine4b.remindAt
          && NoteMerge.carryFields(draft: mine4b, base: base4, theirs: { var t = theirs4; t.remindAt = Date(timeIntervalSince1970: 1_700_000_000); return t }()).remindAt == mine4b.remindAt)
    var mine4c = mine4; mine4c.remindAt = Date(timeIntervalSince1970: 1_800_050_000)
    check("later still means theirs when theirs is the later one", NoteMerge.carryFields(draft: mine4c, base: base4, theirs: theirs4).remindAt == theirs4.remindAt)
    var mine4d = mine4; mine4d.tags = ["a", "m"]
    check("tags changed on both sides are joined", NoteMerge.carryFields(draft: mine4d, base: base4, theirs: theirs4).tags == ["a", "m", "b"])

    // F5: a number typed after a dash is the sentence, not a doubled marker
    let dashText = "- a\n- "
    if let da = ListEdit.autoMarker(dashText, caret: (dashText as NSString).length) {
        let typed = dashText + "2020. "
        check("2020. typed after a dash item is kept", ListEdit.absorbTyped(typed, caret: (typed as NSString).length, auto: da) == nil)
        let typed1 = dashText + "1. "
        check("1. typed after a dash item is kept", ListEdit.absorbTyped(typed1, caret: (typed1 as NSString).length, auto: da) == nil)
    } else { check("2020. typed after a dash item is kept", false, "no marker") }
    let numText = "1. a\n2. "
    if let na = ListEdit.autoMarker(numText, caret: (numText as NSString).length) {
        let wide = numText + "20. "
        check("a wider number than the automatic one is kept", ListEdit.absorbTyped(wide, caret: (wide as NSString).length, auto: na) == nil)
        let same = numText + "2. "
        let r5 = ListEdit.absorbTyped(same, caret: (same as NSString).length, auto: na)
        check("the same number typed again is still folded in", r5 != nil && ((same as NSString).replacingCharacters(in: r5!.range, with: r5!.replacement)) == "1. a\n2. ")
        let dashOver = numText + "- "
        check("a dash typed after a number item is kept", ListEdit.absorbTyped(dashOver, caret: (dashOver as NSString).length, auto: na) == nil)
    }

    // F6: a table goes after the selection and the selected words stay
    let tsel = NoteFormat.table("keep this sentence safe", NSRange(location: 5, length: 4))
    check("a table inserted with words selected leaves them in place, selected", tsel.text.hasPrefix("keep this\n| Column 1") && tsel.text.hasSuffix(" sentence safe")
          && tsel.selection == NSRange(location: 5, length: 4), tsel.text)

    // another program changing a note's words while words typed in the editor are unsaved
    let baseNote = Note(id: "n", title: "T", body: "base", tags: [], created: Date())
    var typedHere = baseNote; typedHere.body = "base and mine"
    var typedThere = baseNote; typedThere.body = "base and theirs"
    var retagged = baseNote; retagged.tags = ["x"]
    check("their words and unsaved words here are a clash to settle", NoteMerge.wordsClash(base: baseNote, draft: typedHere, theirs: typedThere))
    check("nothing typed here, or nothing changed there, or the same words on both sides, is not",
          !NoteMerge.wordsClash(base: baseNote, draft: baseNote, theirs: typedThere) && !NoteMerge.wordsClash(base: baseNote, draft: typedHere, theirs: retagged)
          && !NoteMerge.wordsClash(base: baseNote, draft: typedHere, theirs: typedHere))

    // the shared timer templates, as the phone writes them, offered in a reminder's picker
    let realKey = TimerStore.key
    TimerStore.key = "switchboard.timers.countdowns.probe-finish"
    defer { AppDefaults.store.removeObject(forKey: TimerStore.key); TimerStore.key = realKey }
    let ts = TimerStore()
    ts.chimeAloud = false
    defer { ts.stop() }
    let runs = Runs(timers: ts, writes: false)
    put(".reminders/templates/t-pasta.json", "{\"id\":\"t-pasta\",\"kind\":\"timer\",\"label\":\"Pasta\",\"minutes\":10,\"color\":\"orange\",\"created\":2}")
    put(".reminders/templates/t-oven.json", "{\"id\":\"t-oven\",\"kind\":\"timer\",\"label\":\"Oven\",\"minutes\":120,\"color\":\"red\",\"created\":1}")
    runs.reload()
    let offered = WhenTemplate.shared(runs.templates)
    check("a reminder's picker offers the templates in .reminders/templates, newest first", offered.map(\.title) == ["10 min Pasta", "2 h Oven"], "\(offered.map(\.title))")
    let now = Date(timeIntervalSince1970: 1_000_000)
    check("a template sets the time that many minutes ahead", offered.first?.date(from: now) == now.addingTimeInterval(600))
    // the later probes start from an empty inbox
    try? fm.removeItem(atPath: NotesInbox.path)
    try? fm.removeItem(atPath: NotesInbox.seenPath)
    return lines
}
