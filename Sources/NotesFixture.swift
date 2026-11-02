// NotesFixture.swift
// Notes with awkward shapes, seeded into a scratch store so pictures and
// drives cover more than one tidy note: long and non-Latin titles, a body
// with every markdown block, many tags, every mark a row can wear.

import Foundation

enum NotesFixture {
    /// Saves of every shape: a short link, a very long one, a Mac folder, a file, a thought with no link, and tags with colours.
    static func seedSaved(_ s: SavedStore) {
        guard s.items.isEmpty else { return }
        s.add(url: "https://news.ycombinator.com/item?id=41", title: "Unix pipeline explainer", tags: ["read-later", "unix"])
        s.add(url: "https://example.com/a-very-long-article-title-about-nothing-in-particular/with/a/long/path?and=a&long=query#heading", title: "", tags: ["read-later"])
        s.add(url: "file:///Users/alcatraz627/Code/", title: "Code", tags: ["work"])
        s.add(url: "file:///Users/alcatraz627/Notes/feedback.md", title: "", tags: ["work", "notes"])
        s.add(url: "", title: "Ask about the csync deploy", tags: [])
        s.add(url: "https://example.com/unbroken", title: "Unbroken_" + String(repeating: "abcdefghij", count: 14), tags: ["read-later"])
        s.add(url: "https://github.com/alcatraz627/mnt-sync", title: "A repository title long enough to need cutting in the middle of the row, which is what the owner asked for", tags: [])
        TagColors.set("read-later", to: "teal"); TagColors.set("work", to: "#f97316"); TagColors.set("unix", to: "purple")
        s.load()
    }

    /// What arrived from elsewhere: a note and a save from the phone, and one note an agent wrote, with no notification.
    static func seedInbox(_ s: NotesStore) {
        NotesInbox.deliver = { _, _, _ in }
        guard let phone = s.add(title: "Pick up the parcel on the way home and then a long, long title that does not fit the inbox row at all", body: "from the phone, in the queue"),
              var agent = s.add(title: "Agent finding: the deploy log is clean", body: "nothing to do") else { return }
        agent.agent = "claude-1"; s.update(agent)
        // --demo-bulk: a first sync that brings more notes than are listed one by one
        if CommandLine.arguments.contains("--demo-bulk") {
            let many = (0..<32).compactMap { s.add(title: "Imported note \($0)", body: "from the first sync")?.id }
            NotesInbox.shared.ingest(ids: many, dir: NotesStore.dir, author: { _ in "the phone" })
        }
        if var missed = s.add(title: "Call the dentist", body: "rang while nobody was at the desk") { missed.remindAt = Date().addingTimeInterval(-7200); s.update(missed) }
        let link = SavedStore.shared.add(url: "https://example.com/shared-from-the-phone", title: "A page shared from the phone")
        NotesInbox.shared.ingest(ids: [phone.id, ".saved/" + (link?.id ?? ""), agent.id], dir: NotesStore.dir, author: { _ in "the phone" })
    }

    /// The markdown-heavy note goes in last, so it is the newest and the one a snapshot opens.
    static func seed(_ s: NotesStore) {
        func put(_ title: String, _ body: String, color: String? = nil, tags: [String] = [], pinned: Bool = false,
                 agent: String? = nil, source: String? = nil, url: String? = nil, remind: TimeInterval? = nil, expires: TimeInterval? = nil) {
            guard var n = s.add(title: title, body: body, color: color) else { return }
            n.tags = tags; n.pinned = pinned; n.agent = agent; n.source = source; n.url = url
            n.remindAt = remind.map { Date().addingTimeInterval($0) }
            n.expires = expires.map { Date().addingTimeInterval($0) }
            s.update(n)
            // one second apart, so ids and the newest-first order stay stable
            Thread.sleep(forTimeInterval: 1.05)
        }
        put("Expired last week", "gone but kept", expires: -7 * 86400)
        put("", "A note with no title at all, only this body, which is long enough to wrap onto a second line in the row.")
        put("Ping the Pi", "<<<<<<< HEAD\nmine: restart tonight\n=======\ntheirs: restart now\n>>>>>>> pi/main\n", color: "red", tags: ["pi"])
        put("From the Pi agent", "The agent wrote this one.", tags: ["agent", "auto"], agent: "pi")
        put("Unix pipeline explainer", "", tags: ["pin", "reading"], source: "csync", url: "https://example.com/pipes")
        put("Café ☕ 中文 — a title long enough to test how the row and the open note treat a line that will not fit",
            "Short body.", color: "purple", tags: ["long", "unicode", "wrapping", "many", "tags", "here", "seven"], pinned: true, remind: 3600)
        // titles that give a row no place to break: one unbroken run, and one of the 200 characters a title may hold
        put("Unbroken_" + String(repeating: "abcdefghij", count: 14), "no spaces in that title to wrap at", tags: ["unbroken"])
        put(String(repeating: "A title that keeps going and going ", count: 6), "a title cut at 200 characters", color: "orange")
        put("Groceries and the Pi",
            """
            # Before Sunday
            - milk, eggs, **coffee**
            - [x] the Pi's SD card (32 GB)
            - [ ] ask about the `csync` deploy

            ## Then
            1. sync the notes
            2. read [the plan](https://example.com/plan)

            ```
            ssh pi 'systemctl --user restart csync-media'
            ```
            ![missing picture](attachments/none.png)
            A closing line with _italic_ and a very long word: Donaudampfschifffahrtsgesellschaftskapitän.
            """, color: "green", tags: ["home", "pi"], remind: 86400)
        TagColors.set("pi", to: "teal"); TagColors.set("home", to: "#f97316"); TagColors.set("reading", to: "purple")
    }
}
