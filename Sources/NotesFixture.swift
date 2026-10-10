// NotesFixture.swift
// Notes with awkward shapes, seeded into a scratch store so pictures and
// drives cover more than one tidy note: long and non-Latin titles, a body
// with every markdown block, many tags, every mark a row can wear.

import Foundation

enum NotesFixture {
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
    }
}
