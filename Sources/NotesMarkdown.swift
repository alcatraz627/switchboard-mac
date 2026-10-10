// NotesMarkdown.swift
// A note's body laid out for reading: headings, lists, tasks, code, images
// from the notes folder, and inline bold, italic, code and links. Enough for
// notes, not a markdown engine; what it does not know it shows as a line.

import AppKit
import SwiftUI

struct MarkdownBody: View {
    let text: String
    /// The notes folder, where a relative image path starts.
    let dir: String

    enum Block: Equatable {
        case heading(Int, String), bullet(String), numbered(String, String), task(Bool, String)
        case code(String), image(String, String), para(String), blank
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var code: [String]? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { out.append(.blank); continue }
            if let m = line.firstMatch(of: #/^(#{1,3})\s+(.*)$/#) { out.append(.heading(m.1.count, String(m.2))); continue }
            if let m = line.firstMatch(of: #/^[-*]\s+\[([ xX])\]\s+(.*)$/#) { out.append(.task(m.1 != " ", String(m.2))); continue }
            if let m = line.firstMatch(of: #/^[-*]\s+(.*)$/#) { out.append(.bullet(String(m.1))); continue }
            if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) { out.append(.numbered(String(m.1), String(m.2))); continue }
            if let m = line.firstMatch(of: #/^!\[([^\]]*)\]\(([^)]+)\)$/#) { out.append(.image(String(m.1), String(m.2))); continue }
            out.append(.para(line))
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let n, let s):
            inline(s).font(.sb(n == 1 ? 15 : n == 2 ? 13.5 : 12.5, weight: .semibold)).padding(.top, 3)
        case .bullet(let s): row("•", s)
        case .numbered(let n, let s): row(n + ".", s)
        case .task(let done, let s):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: done ? "checkmark.square" : "square").font(.sbIcon(11)).foregroundStyle(.secondary).padding(.top, 2)
                inline(s).strikethrough(done).foregroundStyle(done ? Color.secondary : Color.primary)
            }
        case .code(let s):
            Text(s).font(.sb(11).monospaced()).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        case .image(let alt, let path): image(alt, path)
        case .para(let s): inline(s)
        case .blank: Color.clear.frame(height: 2)
        }
    }

    private func row(_ mark: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark).font(.sb(12)).foregroundStyle(.secondary).frame(minWidth: 10, alignment: .trailing)
            inline(s)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a).font(.sb(12))
        }
        return Text(s).font(.sb(12))
    }

    @ViewBuilder private func image(_ alt: String, _ path: String) -> some View {
        let full = path.hasPrefix("/") ? path : dir + "/" + path
        if let img = NSImage(contentsOfFile: full) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help(alt.isEmpty ? path : alt)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "photo").font(.sbIcon(10))
                Text(alt.isEmpty ? path : alt).font(PT.caption)
            }
            .foregroundStyle(.tertiary)
        }
    }
}

/// The reader's parsing, checked without a window.
func probeMarkdown() -> [String] {
    var lines: [String] = []
    func check(_ name: String, _ ok: Bool, _ got: String = "") {
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok || got.isEmpty ? "" : " (got: \(got))")")
    }
    let b = MarkdownBody.blocks("# Plan\n\n- milk\n- [x] eggs\n1. first\n```\ncode here\n```\n![pic](attachments/a.png)\nplain **bold**")
    check("a heading, a bullet, a done task, a numbered line, a code block, an image and a paragraph each become their block",
          b == [.heading(1, "Plan"), .blank, .bullet("milk"), .task(true, "eggs"), .numbered("1", "first"), .code("code here"),
                .image("pic", "attachments/a.png"), .para("plain **bold**")], "\(b)")
    check("an unclosed code fence still ends as code", MarkdownBody.blocks("```\nx").last == .code("x"))
    check("a line that is not markdown is a paragraph", MarkdownBody.blocks("just words").first == .para("just words"))
    return lines
}
