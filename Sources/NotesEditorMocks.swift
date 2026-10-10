// NotesEditorMocks.swift
// Three shapes the full notes editor could take, drawn with the real kit so
// the owner picks one on a decision page before any of them is built. Nothing
// here is wired to a store: every mock shows the same made-up note.
// Drawn by `--snapshot-editor-mock a|b|c <out.png> [--light]`.

import SwiftUI

enum EditorMock {
    static let title = "Groceries and the Pi"
    static let body = """
    Before Sunday:
    - milk, eggs, **coffee**
    - the Pi's SD card (32 GB)

    Ask about the `csync` deploy, then sync the notes.
    """
    static let tags = ["home", "pi"]

    /// Mock A: the row's sheet grows a formatting line and colour name; the list stays.
    static func a() -> AnyView { AnyView(SheetGrowsMock()) }
    /// Mock B: the open note takes the whole tab; Esc is the way back to the list.
    static func b() -> AnyView { AnyView(TakeoverMock(preview: false)) }
    /// Mock C: as B, with a Write / Read switch that renders the markdown.
    static func c() -> AnyView { AnyView(TakeoverMock(preview: true)) }
}

/// The bits every mock shares, kept short so the three read as one family.
private enum MockBits {
    static func formatRow() -> some View {
        HStack(spacing: 4) {
            ForEach(["B", "I", "‹›", "• list", "☐ task", "link"], id: \.self) { t in
                Text(t).font(.sb(10.5, weight: t == "B" ? .bold : .regular))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) { KeyPill(text: "⌘↩"); Text("save").font(PT.caption).foregroundStyle(.tertiary) }
            HStack(spacing: 4) { KeyPill(text: "Esc"); Text("list").font(PT.caption).foregroundStyle(.tertiary) }
        }
    }
    static func chip(_ icon: String, _ text: String, set: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: set ? icon : "plus").font(.sbIcon(10, weight: .medium))
            Text(text).font(.sb(11))
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(set ? Color.accentColor.opacity(0.14) : Color.clear))
        .overlay(Capsule().strokeBorder(set ? Color.clear : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .foregroundStyle(set ? Color.accentColor : .secondary)
    }
    static func tagChips() -> some View {
        HStack(spacing: 5) {
            ForEach(EditorMock.tags, id: \.self) { t in
                Text("#" + t).font(.sb(10.5)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Text("+ tag").font(.sb(10.5)).foregroundStyle(.tertiary)
        }
    }
    static func colourName() -> some View {
        HStack(spacing: 5) {
            Circle().fill(timerColors[3].1).frame(width: si(9), height: si(9))
            Text(timerColors[3].0).font(.sb(11)).foregroundStyle(.secondary)
        }
    }
    static func versions() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath").font(.sbIcon(10))
            Text("4 versions").font(.sb(11))
        }.foregroundStyle(.secondary).fixedSize()
    }
    /// One row when it fits, two when it does not, as the real editor's footer does.
    static func footer(saved: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chip("hourglass", "Expiry"); chip("bell", "Reminds 12 Oct, 9:00 AM", set: true); versions()
                Spacer(minLength: 6)
                Text(saved).font(PT.caption).foregroundStyle(.tertiary).fixedSize()
                Image(systemName: "trash").font(.sbIcon(11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { chip("hourglass", "Expiry"); chip("bell", "Reminds 12 Oct, 9:00 AM", set: true); Spacer(minLength: 0) }
                HStack(spacing: 6) {
                    versions()
                    Text(saved).font(PT.caption).foregroundStyle(.tertiary).fixedSize()
                    Spacer()
                    Image(systemName: "trash").font(.sbIcon(11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    static func closedRow(_ title: String, _ sub: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.sbIcon(10)).foregroundStyle(.quaternary)
            Circle().strokeBorder(Color.primary.opacity(0.25)).frame(width: si(9), height: si(9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PT.label)
                Text(sub).font(PT.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV)
    }
    /// The sheet as text: a live text view has no height until it is laid out in a window.
    static func sheet() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(EditorMock.title).font(.sb(13, weight: .semibold)).padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
            Divider().opacity(0.5).padding(.horizontal, 8)
            Text(EditorMock.body).font(.sb(12)).lineSpacing(2).padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    static func rendered() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before Sunday:").font(.sb(12))
            ForEach(["milk, eggs, **coffee**", "the Pi's SD card (32 GB)"], id: \.self) { l in
                HStack(alignment: .top, spacing: 6) { Text("•"); Text(try! AttributedString(markdown: l)).font(.sb(12)) }
            }
            Text(try! AttributedString(markdown: "Ask about the `csync` deploy, then sync the notes.")).font(.sb(12))
        }
    }
}

private struct SheetGrowsMock: View {
    @State private var title = EditorMock.title
    @State private var body_ = EditorMock.body
    @State private var focus: NoteSheet.Field? = .body

    var body: some View {
        VStack(alignment: .leading, spacing: PT.gap) {
            HStack(spacing: 6) {
                Circle().strokeBorder(Color.primary.opacity(0.25)).frame(width: si(9), height: si(9))
                Text("New note").font(PT.label).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                ForEach(["arrow.up.left.and.arrow.down.right", "checkmark", "pin", "doc.on.clipboard"], id: \.self) {
                    Image(systemName: $0).font(.sbIcon(11)).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").font(.sbIcon(10)).foregroundStyle(.quaternary)
                        MockBits.colourName()
                        Text(EditorMock.title).font(PT.label)
                        Spacer()
                        Image(systemName: "doc.on.doc").font(.sbIcon(11)).foregroundStyle(.secondary)
                        Image(systemName: "pin").font(.sbIcon(11)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4).padding(.trailing, PT.rowH).padding(.vertical, PT.rowV)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            MockBits.formatRow().padding(.horizontal, 8).padding(.top, 7)
                            MockBits.sheet()
                            HStack(spacing: 3) { Text("#").font(PT.caption).foregroundStyle(.tertiary); MockBits.tagChips() }
                                .padding(.horizontal, 8).padding(.vertical, 3).padding(.bottom, 4)
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                        MockBits.footer(saved: "Saves as you type")
                    }
                    .padding(.horizontal, PT.rowH).padding(.bottom, 10).padding(.top, 2)
                    Divider().padding(.leading, PT.rowH)
                    MockBits.closedRow("Call the bank", "reminds 13 Oct, 1:00 PM")
                    Divider().padding(.leading, PT.rowH)
                    MockBits.closedRow("Switchboard next", "keybinds, widgets, notes · #plan")
                }
            }
        }
        .padding(PT.gap)
        .frame(width: PT.width)
    }
}

private struct TakeoverMock: View {
    let preview: Bool
    @State private var title = EditorMock.title
    @State private var body_ = EditorMock.body
    @State private var focus: NoteSheet.Field? = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 4) { KeyPill(text: "Esc"); Text("All notes").font(PT.caption).foregroundStyle(.secondary) }
                Spacer()
                if preview {
                    HStack(spacing: 0) {
                        Text("Write").font(.sb(11)).padding(.horizontal, 9).padding(.vertical, 3)
                        Text("Read").font(.sb(11, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                MockBits.colourName()
                Image(systemName: "pin").font(.sbIcon(11)).foregroundStyle(.secondary)
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    if preview {
                        Text(EditorMock.title).font(.sb(15, weight: .semibold)).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                        HStack(spacing: 3) { Text("#").font(PT.caption).foregroundStyle(.tertiary); MockBits.tagChips() }.padding(.horizontal, 10).padding(.bottom, 6)
                        Divider().opacity(0.5).padding(.horizontal, 8)
                        MockBits.rendered().padding(10).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                    } else {
                        MockBits.formatRow().padding(.horizontal, 8).padding(.top, 7)
                        MockBits.sheet().frame(minHeight: 300, alignment: .top)
                        HStack(spacing: 3) { Text("#").font(PT.caption).foregroundStyle(.tertiary); MockBits.tagChips() }
                            .padding(.horizontal, 8).padding(.vertical, 3).padding(.bottom, 6)
                    }
                }
            }
            MockBits.footer(saved: "Saved 2m ago")
        }
        .padding(PT.gap)
        .frame(width: PT.width)
    }
}
