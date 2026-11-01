// NotesSpec.swift
// The notes folder format as written in mnt-sync's specs/notes.md, with no app in it: read a file's
// text into its fields, write the fields back, and the small rules around them (valid ids and keys, the
// file name of a save). The Notes store maps these fields onto a Note, and the fixture probe checks
// this file against every fixture in the spec.

import Foundation
import CryptoKit

enum NoteSpec {
    /// Every field a note file can hold. Dates stay as the text found, as the spec's reader does.
    struct Record: Equatable {
        var title = ""
        var body = ""
        var tags: [String] = []
        var color: String?
        var pinned = false
        var pos: String?
        var url: String?
        var device: String?
        var agent: String?
        var source: String?
        var expires: String?
        var created: String?
        var remindAt: String?
        var remindRepeat: String?
        var remindOn: String?
        var remindPersist = false
        var reminderId: String?
        var conflicted = false
        var extraLines: [String] = []
        /// The colour value as found, even when it is not one of the eight. Switchboard's own added dots are named
        /// here; the spec's `color` stays nil for them, so another app reads them as no colour.
        var rawColor: String?
        /// True when the title came from the body's first line, so an editor can lift that line out of its body field.
        var titleFromBody = false
    }

    static let colors: Set<String> = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]
    static let known: Set<String> = ["title", "created", "tags", "expires", "remind_at", "remind_repeat", "remind_on", "remind_persist",
                                     "reminder_id", "pinned", "color", "agent", "source", "url", "device", "pos"]

    // ── Reading ─────────────────────────────────────────────────────────────

    /// The text of one header value: JSON-quoted, YAML single-quoted, or bare. A quote that is not valid JSON stays as written.
    static func value(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") {
            if let d = try? JSONSerialization.jsonObject(with: Data("[\(v)]".utf8)) as? [String], d.count == 1 { return d[0] }
            return v
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return v
    }

    /// `a, b` and `[a, b]` (with or without quotes round each) read the same; empty entries go.
    static func tagList(_ v: String) -> [String] {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        return s.split(separator: ",", omittingEmptySubsequences: true).map { part -> String in
            var t = part.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { t = String(t.dropFirst().dropLast()) }
            return t.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    static func read(_ raw: String, name: String) -> Record {
        let whole = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var r = Record()
        if NotesSync.conflicted(whole) {
            r.conflicted = true; r.title = name; r.body = whole
            return r
        }
        let lines = whole.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var body = whole
        if lines.first == "---", let close = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) {
            for line in lines[1..<close] {
                guard let c = line.firstIndex(of: ":") else {
                    // a line with no colon is kept; a blank one is not
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { r.extraLines.append(line) }
                    continue
                }
                let key = String(line[..<c])
                guard known.contains(key) else { r.extraLines.append(line); continue }
                fields[key] = value(String(line[line.index(after: c)...]))
            }
            body = lines[(close + 1)...].joined(separator: "\n")
        }
        r.body = body
        if let t = fields["title"] {
            r.title = t.trimmingCharacters(in: .whitespaces)
        } else {
            let first = body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            let t = String(first.drop { $0 == "#" || $0 == ">" || $0 == " " || $0 == "\t" }).trimmingCharacters(in: .whitespaces)
            r.title = t.isEmpty ? name : t
            r.titleFromBody = !t.isEmpty
        }
        func text(_ k: String) -> String? { fields[k].flatMap { $0.isEmpty ? nil : $0 } }
        r.tags = tagList(fields["tags"] ?? "")
        r.rawColor = text("color")
        r.color = text("color").flatMap { colors.contains($0) ? $0 : nil }
        r.pinned = fields["pinned"] == "true"
        r.pos = text("pos").flatMap { validPos($0) ? $0 : nil }
        r.url = text("url"); r.device = text("device"); r.agent = text("agent"); r.source = text("source")
        r.expires = text("expires"); r.created = text("created"); r.remindAt = text("remind_at")
        r.remindRepeat = text("remind_repeat").flatMap { ["daily", "weekly", "monthly"].contains($0) ? $0 : nil }
        r.remindOn = text("remind_on").flatMap { ["mac", "phone"].contains($0) ? $0 : nil }
        r.remindPersist = fields["remind_persist"] == "true"
        r.reminderId = text("reminder_id")
        return r
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    /// A string as JSON, without a backslash before a slash.
    static func quoted(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// Keys in the spec's order, empty values left out except the title, unknown lines after the known ones.
    static func render(_ r: Record) -> String {
        var l = ["---", "title: " + quoted(r.title)]
        func put(_ key: String, _ v: String?, json: Bool = false) {
            guard let v, !v.isEmpty else { return }
            l.append(key + ": " + (json ? quoted(v) : v))
        }
        put("created", r.created)
        if !r.tags.isEmpty { l.append("tags: " + quoted(r.tags.joined(separator: ", "))) }
        put("expires", r.expires)
        put("remind_at", r.remindAt); put("remind_repeat", r.remindRepeat); put("remind_on", r.remindOn)
        if r.remindPersist { l.append("remind_persist: true") }
        put("reminder_id", r.reminderId, json: true)
        if r.pinned { l.append("pinned: true") }
        put("color", r.color)
        put("agent", r.agent, json: true); put("source", r.source, json: true); put("url", r.url, json: true); put("device", r.device, json: true)
        put("pos", r.pos)
        l += r.extraLines
        l.append("---")
        return l.joined(separator: "\n") + "\n" + r.body
    }

    // ── Small rules ─────────────────────────────────────────────────────────

    /// `[0-9a-z]{0,31}[1-9a-z]`
    static func validPos(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...32).contains(u.count), u.last != 48 else { return false }
        return u.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }
    }

    /// `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`
    static func validID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...64).contains(u.count) else { return false }
        func alnum(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        return alnum(u[0]) && u.dropFirst().allSatisfy { alnum($0) || $0 == 95 || $0 == 45 }
    }

    /// Spaces trimmed, scheme and host lowercased, everything else as written.
    static func normalisedURL(_ raw: String) -> String {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = u.firstIndex(of: ":") else { return u }
        let scheme = u[..<colon].lowercased()
        let rest = u[u.index(after: colon)...]
        guard rest.hasPrefix("//") else { return scheme + ":" + rest }
        let after = rest.dropFirst(2)
        let end = after.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? after.endIndex
        let authority = after[..<end]
        var user = ""
        var host = String(authority)
        if let at = authority.lastIndex(of: "@") { user = String(authority[...at]); host = String(authority[authority.index(after: at)...]) }
        return scheme + "://" + user + host.lowercased() + after[end...]
    }

    /// The file name of a save: 12 hex characters of the SHA-1 of its normalised link.
    static func saveKey(_ url: String) -> String {
        Insecure.SHA1.hash(data: Data(normalisedURL(url).utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// True when a clash may be settled with no one asking: under `.reminders/`, or when every
    /// changed line in every (closed) block is `pos:`. A file with no clash is not a clash to settle.
    static func autoSettles(_ text: String, path: String) -> Bool {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard NotesSync.conflicted(t) else { return false }
        return path.hasPrefix(".reminders/") || NotesSync.posOnlyClash(t)
    }
}
