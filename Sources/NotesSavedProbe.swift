// NotesSavedProbe.swift
// Headless checks for Saved: adding, tagging, removing, opening, and the one-time move of older pins,
// all in a scratch folder with its own git repository. Nothing here touches the owner's notes.

import Foundation

func probeSaved() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "sb-saved-\(getpid())"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let defaults = NotesStore.defaults
    let oldFolder = defaults.string(forKey: NotesStore.folderKey)
    defaults.set(root + "/notes", forKey: NotesStore.folderKey)
    defaults.removeObject(forKey: SavedStore.migratedKey)
    defaults.removeObject(forKey: NotesSync.remoteKey)
    defer {
        if let f = oldFolder { defaults.set(f, forKey: NotesStore.folderKey) } else { defaults.removeObject(forKey: NotesStore.folderKey) }
        defaults.removeObject(forKey: SavedStore.migratedKey)
    }
    @discardableResult func g(_ a: String...) -> GitResult { NotesSync.runGit(a, cwd: root + "/notes") }
    func read(_ f: String) -> String { (try? String(contentsOfFile: root + "/notes/" + f, encoding: .utf8)) ?? "" }
    func put(_ f: String, _ t: String) { try? t.write(toFile: root + "/notes/" + f, atomically: true, encoding: .utf8) }

    NotesStore.remindersOff = true
    let sync = NotesSync.shared
    check("the scratch folder becomes a repository", sync.ensureRepo())
    g("config", "user.name", "T"); g("config", "user.email", "t@t")
    let store = SavedStore()

    // adding
    let page = store.add(url: "  HTTPS://Example.COM/a?b=1 ", title: "")
    check("a saved link is one file named by the hash of its link", page?.id == "8849d9f8cb0c" && fm.fileExists(atPath: root + "/notes/.saved/8849d9f8cb0c.md"), page?.id ?? "nil")
    check("its file holds the link in the spec's format", read(".saved/8849d9f8cb0c.md").contains("url: \"https://example.com/a?b=1\"") && read(".saved/8849d9f8cb0c.md").hasPrefix("---\ntitle: "))
    check("the same link again is one file, not two", store.add(url: "https://example.com/a?b=1")?.id == "8849d9f8cb0c" && store.items.count == 1)
    let folder = store.add(url: "file:///Users/me/Code/", title: "Code")
    check("a Mac folder link is marked as opening on the Mac only", folder?.device == "mac" && read(".saved/\(folder?.id ?? "x").md").contains("device: \"mac\""))
    check("a save needs a title, text or a link", store.add(url: "", title: "") == nil)
    check("a save with a title and no link takes a note-style id", store.add(url: "", title: "Just a thought")?.id.count == 20)
    check("a pasted path becomes a file link, a folder with a closing slash",
          SavedInput.link(from: "~/") .hasPrefix("file:///") && SavedInput.link(from: "~/").hasSuffix("/") && SavedInput.link(from: "https://x.test/a") == "https://x.test/a")
    check("Saved is not part of the note list: no .md sits at the top level", !(((try? fm.contentsOfDirectory(atPath: root + "/notes")) ?? []).contains { $0.hasSuffix(".md") }))

    // tagging, reading back
    store.setTags("8849d9f8cb0c", ["read-later", " work "])
    store.load()
    check("tags are kept in the file and read back", store.items.first { $0.id == "8849d9f8cb0c" }?.tags == ["read-later", "work"] && read(".saved/8849d9f8cb0c.md").contains("tags: \"read-later, work\""))

    // a commit takes them
    sync.commitNow("save")
    check("saves are committed with the notes", g("ls-files", ".saved").out.contains(".saved/8849d9f8cb0c.md"))

    // opening
    check("a web link opens", SavedStore.opening(page!) == .open(URL(string: "https://example.com/a?b=1")!))
    var phone = Note(id: "p", title: "p", body: "", tags: [], created: Date()); phone.url = "file:///Users/me/x.pdf"; phone.device = "phone"
    if case .cannot(let why) = SavedStore.opening(phone) { check("a file link made for the phone says so and does not open", why.contains("phone")) } else { check("a file link made for the phone says so and does not open", false) }
    var gone = phone; gone.device = "mac"; gone.url = "file://" + root + "/nothing-here.pdf"
    if case .cannot(let why) = SavedStore.opening(gone) { check("a Mac file that is not there says so", why.contains("not on this Mac")) } else { check("a Mac file that is not there says so", false) }
    put("real.txt", "x")
    var real = gone; real.url = URL(fileURLWithPath: root + "/notes/real.txt").absoluteString
    check("a Mac file that is there opens", SavedStore.opening(real) == .open(URL(string: real.url!)!))

    // removing
    store.remove(key: "8849d9f8cb0c")
    check("remove takes the file out of Saved", !fm.fileExists(atPath: root + "/notes/.saved/8849d9f8cb0c.md") && !store.items.contains { $0.id == "8849d9f8cb0c" })
    sync.commitNow("save")
    check("and its history is still in git", g("log", "--oneline", "--", ".saved/8849d9f8cb0c.md").out.split(separator: "\n").count >= 1)

    // tag colours
    TagColors.set("work", to: "#3b82f6"); TagColors.set("read-later", to: "teal")
    check("tag colours are written to .meta/tags.json and read back", TagColors.read() == ["work": "#3b82f6", "read-later": "teal"] && TagColors.color("#3b82f6") != nil && TagColors.color("teal") != nil && TagColors.color("mauve") == nil)
    TagColors.set("work", to: nil)
    check("clearing a tag's colour keeps the others", TagColors.read() == ["read-later": "teal"])

    // the one-time move of older pins
    try? fm.removeItem(atPath: root + "/notes/.saved")
    sync.commitNow("save")
    put("pin1.md", "---\ntitle: \"Docs\"\ncreated: 2026-10-01T00:00:00Z\ntags: \"pin, docs\"\nurl: \"https://example.com/docs\"\n---\nbody words\n")
    put("pin2.md", "---\ntitle: \"A folder\"\nurl: \"file:///Users/me/Code/\"\n---\n")
    put("pin3.md", "---\ntitle: \"Tagged only\"\ntags: \"pin\"\n---\nno link, only the tag\n")
    put("zdup.md", "---\ntitle: \"Docs again\"\nurl: \"HTTPS://example.com/docs\"\n---\n")
    put("plain.md", "---\ntitle: \"Plain\"\ntags: \"work\"\n---\njust a note\n")
    sync.commitNow("save")
    let commitsBefore = Int(g("rev-list", "--count", "HEAD").out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let moved = SavedStore().migrateOldPinsIfNeeded()
    let commitsAfter = Int(g("rev-list", "--count", "HEAD").out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let docsKey = NoteSpec.saveKey("https://example.com/docs")
    check("four older pins move and the plain note stays", moved == 4 && fm.fileExists(atPath: root + "/notes/plain.md")
          && !fm.fileExists(atPath: root + "/notes/pin1.md") && !fm.fileExists(atPath: root + "/notes/pin3.md"), "\(moved)")
    check("a note with a link takes its hash as the file name", fm.fileExists(atPath: root + "/notes/.saved/\(docsKey).md"))
    check("a note with only the tag keeps its own id", fm.fileExists(atPath: root + "/notes/.saved/pin3.md"))
    check("a second note for the same link keeps its own id so no words are lost", fm.fileExists(atPath: root + "/notes/.saved/zdup.md"))
    check("the pin tag is dropped and other tags and words stay", read(".saved/\(docsKey).md").contains("tags: \"docs\"") && !read(".saved/\(docsKey).md").contains("pin,") && read(".saved/\(docsKey).md").contains("body words"))
    check("a Mac file link gains the device it opens on", read(".saved/\(NoteSpec.saveKey("file:///Users/me/Code/")).md").contains("device: \"mac\""))
    check("the whole move is one commit", commitsAfter == commitsBefore + 1 && g("log", "-1", "--format=%s").out.contains("saved: move 4"), "\(commitsBefore) -> \(commitsAfter)")
    check("the migration key is set", defaults.object(forKey: SavedStore.migratedKey) != nil)
    put("late.md", "---\ntitle: \"Later pin\"\nurl: \"https://example.com/late\"\n---\n")
    check("with the key set a later note with a link stays where it is", SavedStore().migrateOldPinsIfNeeded() == 0 && fm.fileExists(atPath: root + "/notes/late.md"))
    return lines
}
