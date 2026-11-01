// NotesSpecProbe.swift
// Runs every fixture from the notes spec against this app's reader, writer, order, settling and save key.
// The fixtures are vendored under tests/fixtures/notes-spec with a recorded hash, so the probe never needs the
// mnt-sync clone; when that clone is present its fixtures are compared byte for byte with the vendored copy.

import Foundation
import CryptoKit

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let specVendored = repoRoot + "/tests/fixtures/notes-spec"
let specUpstream = NSHomeDirectory() + "/Code/mnt-sync/specs/notes/fixtures"

/// Hash of a fixture folder: every file's relative path and bytes, in path order.
func specFixtureHash(_ dir: String) -> String {
    let fm = FileManager.default
    var h = SHA256()
    let files = ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).sorted()
    for f in files {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir + "/" + f, isDirectory: &isDir), !isDir.boolValue, let d = fm.contents(atPath: dir + "/" + f) else { continue }
        h.update(data: Data(f.utf8)); h.update(data: Data([0])); h.update(data: d); h.update(data: Data([0]))
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

private func recordJSON(_ r: NoteSpec.Record) -> [String: Any] {
    func s(_ v: String?) -> Any { v ?? NSNull() }
    return ["title": r.title, "body": r.body, "tags": r.tags, "color": s(r.color), "pinned": r.pinned, "pos": s(r.pos), "url": s(r.url),
            "device": s(r.device), "agent": s(r.agent), "source": s(r.source), "expires": s(r.expires), "created": s(r.created),
            "remindAt": s(r.remindAt), "remindRepeat": s(r.remindRepeat), "remindOn": s(r.remindOn), "remindPersist": r.remindPersist,
            "reminderId": s(r.reminderId), "conflicted": r.conflicted, "extraLines": r.extraLines]
}

private func renderInput(_ j: [String: Any]) -> NoteSpec.Record {
    func s(_ k: String) -> String? { j[k] as? String }
    var r = NoteSpec.Record()
    r.title = s("title") ?? ""; r.body = s("body") ?? ""; r.tags = (j["tags"] as? [String]) ?? []
    r.color = s("color"); r.pinned = (j["pinned"] as? Bool) ?? false; r.pos = s("pos"); r.url = s("url"); r.device = s("device")
    r.agent = s("agent"); r.source = s("source"); r.expires = s("expires"); r.created = s("created"); r.remindAt = s("remindAt")
    r.remindRepeat = s("remindRepeat"); r.remindOn = s("remindOn"); r.remindPersist = (j["remindPersist"] as? Bool) ?? false
    r.reminderId = s("reminderId"); r.extraLines = (j["extraLines"] as? [String]) ?? []
    return r
}

private func iso(_ s: String?) -> Date {
    s.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date.distantPast
}

/// Every fixture, one line per group and one per failure. `dir` is where the fixtures sit.
func probeSpecFixtures(dir: String = specVendored) -> [String] {
    var lines: [String] = []
    let fm = FileManager.default
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    func text(_ p: String) -> String? { fm.contents(atPath: p).flatMap { String(data: $0, encoding: .utf8) } }
    func json(_ p: String) -> Any? { fm.contents(atPath: p).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    let top = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    guard !top.isEmpty else { return ["FAIL spec fixtures: nothing at \(dir)"] }

    // vendored copy: recorded hash, and the upstream copy when it is here
    if dir == specVendored {
        let recorded = (text(repoRoot + "/tests/fixtures/notes-spec.sha256") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        check("the vendored fixtures match their recorded hash", recorded == specFixtureHash(dir), specFixtureHash(dir))
        if fm.fileExists(atPath: specUpstream) {
            check("the vendored fixtures match the mnt-sync spec's, byte for byte", specFixtureHash(specUpstream) == specFixtureHash(dir),
                  "upstream " + specFixtureHash(specUpstream).prefix(10))
        } else {
            lines.append("skip the mnt-sync clone is not here, so the vendored copy was not compared with it")
        }
    }

    // reading
    var read = 0, bad: [String] = []
    for f in top where f.hasSuffix(".md") {
        let name = String(f.dropLast(3))
        guard let src = text(dir + "/" + f), let want = json(dir + "/" + name + ".json") as? NSDictionary else { continue }
        read += 1
        let got = recordJSON(NoteSpec.read(src, name: name)) as NSDictionary
        if !got.isEqual(want) {
            let diff = want.allKeys.compactMap { k -> String? in
                (got[k] as AnyObject).isEqual(want[k]) ? nil : "\(k): want \(want[k] ?? "nil") got \(got[k] ?? "nil")"
            }
            bad.append(name + " [" + diff.joined(separator: "; ") + "]")
        }
    }
    check("reading: all \(read) fixtures parse to the recorded fields", bad.isEmpty && read > 0, bad.joined(separator: " | "))

    // writing
    var wrote = 0; bad = []
    for f in ((try? fm.contentsOfDirectory(atPath: dir + "/render")) ?? []).sorted() where f.hasSuffix(".json") {
        let name = String(f.dropLast(5))
        guard let want = text(dir + "/render/" + name + ".md"), let j = json(dir + "/render/" + f) as? [String: Any] else { continue }
        wrote += 1
        let rec = renderInput(j)
        let got = NoteSpec.render(rec)
        let back = NoteSpec.read(got, name: name)
        if got != want { bad.append(name + " [bytes differ]") }
        else if back.title != rec.title || back.tags != rec.tags || back.body != rec.body { bad.append(name + " [does not read back]") }
    }
    check("writing: all \(wrote) fixtures render byte for byte and read back", bad.isEmpty && wrote > 0, bad.joined(separator: " | "))

    // settling
    var settled = 0; bad = []
    for f in ((try? fm.contentsOfDirectory(atPath: dir + "/settle")) ?? []).sorted() {
        guard f.hasSuffix(".md"), f.split(separator: ".").count == 2 else { continue }
        let name = String(f.dropLast(3))
        guard let src = text(dir + "/settle/" + f) else { continue }
        let norm = src.replacingOccurrences(of: "\r\n", with: "\n")
        settled += 1
        for (suffix, keep) in [("first", NotesSync.Keep.mine), ("second", .theirs), ("both", .both)] {
            let want = text(dir + "/settle/\(name).\(suffix).md") ?? "<missing>"
            let got = NotesSync.resolve(norm, keep: keep)
            if got != want { bad.append("\(name).\(suffix)") }
        }
    }
    check("settling: all \(settled) clash files give the first, second and both texts", bad.isEmpty && settled > 0, bad.joined(separator: " | "))
    bad = []
    var autos = 0
    if let rows = json(dir + "/settle/auto.json") as? [[String: Any]] {
        for row in rows {
            guard let file = row["file"] as? String, let path = row["path"] as? String, let want = row["auto"] as? Bool,
                  let src = text(dir + "/settle/" + file) else { continue }
            autos += 1
            if NoteSpec.autoSettles(src, path: path) != want { bad.append("\(file) at \(path)") }
        }
    }
    check("settling: the \(autos) automatic-or-ask rows agree", bad.isEmpty && autos > 0, bad.joined(separator: " | "))

    // order
    bad = []
    var cases = 0
    if let rows = json(dir + "/order.json") as? [[String: Any]] {
        for row in rows {
            guard let notes = row["notes"] as? [[String: Any]], let want = row["expected"] as? [String] else { continue }
            cases += 1
            let ns = notes.map { j -> Note in
                var n = Note(id: j["id"] as! String, title: "", body: "", tags: [], created: iso(j["created"] as? String))
                n.pinned = (j["pinned"] as? Bool) ?? false
                n.pos = j["pos"] as? String
                return n
            }
            let got = NoteOrder.sorted(ns.reversed()).map(\.id)
            if got != want { bad.append("\(row["name"] ?? "?"): \(got)") }
        }
    }
    check("order: the \(cases) cases sort as recorded", bad.isEmpty && cases > 0, bad.joined(separator: " | "))

    // pos, ids, save keys
    if let p = json(dir + "/pos.json") as? [String: [String]] {
        let wrong = (p["valid"] ?? []).filter { !NoteSpec.validPos($0) } + (p["invalid"] ?? []).filter { NoteSpec.validPos($0) }
        check("pos: every valid and invalid string is judged as recorded", wrong.isEmpty, wrong.joined(separator: ","))
    }
    if let p = json(dir + "/ids.json") as? [String: [String]] {
        let wrong = (p["valid"] ?? []).filter { !NoteSpec.validID($0) } + (p["invalid"] ?? []).filter { NoteSpec.validID($0) }
        check("ids: every valid and invalid string is judged as recorded", wrong.isEmpty, wrong.joined(separator: ","))
    }
    if let rows = json(dir + "/savekey.json") as? [[String: String]] {
        let wrong = rows.filter { NoteSpec.normalisedURL($0["url"] ?? "") != $0["normalised"] || NoteSpec.saveKey($0["url"] ?? "") != $0["key"] }
        check("save keys: all \(rows.count) links normalise and hash as recorded", wrong.isEmpty, wrong.map { $0["url"] ?? "" }.joined(separator: " | "))
    }

    // the app's own note carries the two newer keys through a save and a read
    var n = Note(id: "rt", title: "Round trip", body: "words", tags: ["a", "b"], created: iso("2026-11-01T10:00:00Z"))
    n.remindAt = iso("2026-11-02T09:00:00Z"); n.remindOn = "phone"; n.remindPersist = true; n.remindRepeat = .weekly
    n.url = "file:///Users/x/Notes/"; n.device = "mac"
    let again = NotesStore.parse(id: "rt", NotesStore.render(n))
    check("remind_persist and device survive a Note written and read again", again?.remindPersist == true && again?.device == "mac"
          && again?.remindOn == "phone" && again?.remindRepeat == .weekly, NotesStore.render(n))
    var plain = n; plain.remindPersist = false; plain.device = nil
    check("and are left out of the file when not set", !NotesStore.render(plain).contains("remind_persist") && !NotesStore.render(plain).contains("device:"))
    let tags = NotesStore.parse(id: "ft", "---\ntitle: \"T\"\ntags: [x, y z]\n---\n")
    check("a note with tags in flow form keeps both tags", tags?.tags == ["x", "y z"], "\(tags?.tags ?? [])")
    return lines
}
