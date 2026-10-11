// Settings.swift
// The Settings tab: which tabs and sections the panel shows, and what the
// hover preview on the menu bar icon carries. A hidden tab or section is
// neither drawn nor read (see Visibility in AppSupport.swift).

import AppKit
import SwiftUI

struct SettingsTab: Identifiable { let id: String; let title: String; let icon: String }

struct SettingsTabView: View {
    @ObservedObject var store: PolicyStore
    /// Tab ids and names in bar order, Settings itself left out.
    let tabs: [(id: String, title: String, icon: String)]

    private var query: String { (store.queries["settings"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    private func matches(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }

    /// Tabs in the owner's order, with those the search leaves out removed.
    private var orderedTabs: [SettingsTab] {
        let rank = Dictionary(store.tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tabs.map { SettingsTab(id: $0.id, title: $0.title, icon: $0.icon) }
            .sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
            .filter { t in matches(t.title) || (Visibility.sections[t.id] ?? []).contains(where: matches) }
    }

    /// The Settings page's own sub-tabs; a search looks across all of them.
    static let sections: [(id: String, title: String, icon: String)] = [
        ("general", "General", "gearshape"), ("tabs", "Tabs", "square.grid.2x2"),
        ("hover", "Hover card", "rectangle.on.rectangle"), ("desk", "Desk", "note.text"),
    ]
    @AppStorage("switchboard.settings.section") private var savedSection = "general"
    /// Set by a snapshot, so a picture never changes the owner's last sub-tab.
    static var sectionOverride: String?
    private var section: String {
        get { Self.sectionOverride ?? savedSection }
        nonmutating set { Self.sectionOverride = nil; savedSection = newValue }
    }
    /// Whether a group on sub-tab `id` shows: always while searching, else only on its own sub-tab.
    private func on(_ id: String) -> Bool { !query.isEmpty || section == id }

    private var sectionBar: some View {
        HStack(spacing: 6) {
            ForEach(Self.sections, id: \.id) { s in
                Button { section = s.id } label: {
                    Label(s.title, systemImage: s.icon).font(.sb(11.5, weight: section == s.id ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(section == s.id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).help(s.title)
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        // a search for "hover" (what the hover card's settings button opens) shows all of the hover's settings
        let hoverAll = matches("hover")
        let hover = HoverItem.allCases.filter { hoverAll || matches($0.title) || matches($0.detail) }
        let pages = quickPages.filter { hoverAll || matches($0.title) }
        let linger = hoverAll || matches("delay") || matches("away") || matches("linger")
        let folder = matches("notes folder") || matches(NotesStore.dir)
        let sizes = matches("size") || matches("small") || matches("medium") || matches("large") || matches("zoom")
        let prompts = matches("permission") || matches("prompt") || matches("claude asks") || matches("approvals")
        let keys = matches("keyboard") || matches("shortcut") || matches("hotkey") || matches("keys")
        let dotSettings = matches("colour") || matches("color") || matches("dot")
        let timerSettings = matches("timer") || matches("sound") || matches("ring") || matches("notes")
        VStack(alignment: .leading, spacing: PT.gap) {
            if query.isEmpty { sectionBar }
            if sizes && on("general") {
                group("Size", note: "How big the panel, the hover card and the menu bar icon are drawn.",
                      rows: [sizeRow])
            }
            if keys && on("general") {
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Keyboard")
                    note("Hold ⌘ anywhere in the panel to see the keys that work there.")
                    Card { keyTable }
                    Card { SystemRowView(row: commandWatchRow, store: store) }
                }
            }
            if (matches("quit") || matches("restart") || matches("login") || matches("switchboard")) && on("general") {
                group("Switchboard", note: "The app itself.", rows: [loginRow, keepScreenRow, restartRow, quitRow])
            }
            if prompts && on("general") {
                group("Claude's permission prompts",
                      note: "When on, a prompt Claude Code would ask in the terminal waits under Claude asks in Approvals for \(PermissionRoute.wait) seconds first.",
                      rows: [promptsRow])
            }
            if !orderedTabs.isEmpty && on("tabs") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        GroupHeader(name: "Tabs")
                        Spacer()
                        if query.isEmpty && store.tabOrder != Visibility.defaultTabOrder {
                            Button("Default order") { store.tabOrder = Visibility.defaultTabOrder }
                                .buttonStyle(.link).font(PT.caption)
                                .help("Put the tabs back in the default order")
                        }
                    }
                    note(query.isEmpty ? "Drag the grip to change a tab's place within its space. Open a tab to choose its sections; hidden ones are not read at all."
                                       : "Matching tabs, opened to the matching sections.")
                    ForEach(Visibility.spaces, id: \.id) { s in
                        let inSpace = orderedTabs.filter { s.tabs.contains($0.id) }
                        if !inSpace.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: s.icon).font(.sbIcon(9.5))
                                Text(s.title).font(PT.caption)
                            }
                            .foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 2)
                            Card {
                                // Dragging stays inside a space: a tab's space is fixed.
                                ReorderStack(items: inSpace, move: { d, t in
                                    if s.tabs.contains(d) { store.moveTab(d, to: t) }
                                }) { i, t, grip in
                                    VStack(spacing: 0) {
                                        if i > 0 { Divider().padding(.leading, PT.rowH) }
                                        HStack(spacing: 0) {
                                            if query.isEmpty && inSpace.count > 1 { grip.padding(.leading, 6) }
                                            SystemRowView(row: tabRow(t), store: store)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !pages.isEmpty && on("hover") {
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Hover pages")
                    note(query.isEmpty ? "The pages the hover card moves through, in this order. Drag the grip to reorder; the switch hides a page."
                                       : "Matching hover pages.")
                    Card {
                        ReorderStack(items: pages, move: { d, t in
                            store.quickPageOrder = reordered(store.quickPageOrder, moving: d, to: t)
                        }) { i, p, grip in
                            VStack(spacing: 0) {
                                if i > 0 { Divider().padding(.leading, PT.rowH) }
                                HStack(spacing: 0) {
                                    if query.isEmpty { grip.padding(.leading, 6) }
                                    SystemRowView(row: pageRow(p), store: store)
                                }
                            }
                        }
                    }
                }
            }
            if (hoverAll || matches("approvals") || matches("waiting")) && on("hover") {
                group("Footer", note: "Under every hover page: Hub, what waits on you with its buttons, and the Claude week.",
                      rows: [approvalsCardRow])
            }
            if linger && on("hover") {
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Mouse-away delay")
                    note("How long the hover card stays after the pointer leaves it.")
                    Card { lingerSlider }
                }
            }
            if !hover.isEmpty && on("hover") {
                group("Now page", note: "The badges on the Now page, and the dot on the menu bar icon.",
                      rows: hover.map(hoverRow))
            }
            if (folder || timerSettings || dotSettings) && on("desk") {
                group("Notes", note: "One markdown file per note, every save kept; the Pi and the phone share the folder.", rows: [notesFolderRow, notesRemoteRow])
                NoteDotsEditor()
                VStack(alignment: .leading, spacing: 5) {
                    GroupHeader(name: "Timers")
                    note("What a timer does when it goes off.")
                    Card {
                        timerSoundRow
                        Divider().padding(.leading, PT.rowH)
                        ringLengthRow
                    }
                }
            }
            if orderedTabs.isEmpty && hover.isEmpty && pages.isEmpty && !linger && !folder && !prompts && !sizes && !keys && !timerSettings && !dotSettings {
                Text("Nothing in Settings matches \"\(query)\".").font(PT.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(PT.gap)
    }

    @ObservedObject private var scale = UIScale.shared

    private var approvalsCardRow: SystemRow {
        var r = SystemRow(label: "Show what waits under every page", state: store.approvalsUnderEveryPage ? .on(menuGreen) : .off,
                          note: store.approvalsUnderEveryPage ? "on" : "off", tip: "",
                          action: { store.approvalsUnderEveryPage.toggle() })
        r.icon = "hand.raised"
        r.key = "settings-approvals-card"
        return r
    }

    /// The keys, one per line, grouped; replaces a paragraph nobody could read.
    static let keyGroups: [(title: String, keys: [(String, String)])] = [
        ("Anywhere", [("⌥Space  ⌘⌘", "Open; again for letters; again to close"),
                      ("⇧⌘P", "Find any action or place"), ("⌘J", "Go to a tab, note or timer")]),
        ("Panel", [("⌘1 – ⌘5", "Pick a space"), ("⌘⌥←  ⌘⌥→", "Tab before or after"),
                   ("⌃Tab", "Next tab anywhere"), ("Tab", "Spaces, tabs, search, rows"),
                   ("⌘L  ⌘F", "Search"), ("⌘P", "Keep the panel open"), ("⌘D", "Pin the tab to the desktop"),
                   ("⌘R", "Reload"), ("Esc", "Step out, then back to your app")]),
        ("Rows", [("↑  ↓", "Move"), ("Return", "What a click does"), ("Space", "Flip a switch"),
                  ("→  ←", "Open, close, step a choice")]),
        ("Approvals", [("Return", "Open a request"), ("⌘↩", "Allow"), ("⌫", "Deny")]),
        ("Notes", [("→  → ", "Open, then edit"), ("Tab", "The note's parts"), ("/", "Search"), ("⌘↩", "Save"),
                   ("P  C", "Pin, copy"), ("1 – 8", "Colour")]),
    ]

    private var keyTable: some View {
        // one grid for every group, so the key column lines up down the whole table
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(Self.keyGroups, id: \.title) { g in
                GridRow {
                    Text(g.title).font(.sb(10, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.top, g.title == Self.keyGroups.first?.title ? 0 : 6)
                        .gridCellColumns(2)
                }
                ForEach(g.keys, id: \.0) { k, what in
                    GridRow {
                        Text(k).font(.sb(11, weight: .medium).monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                            .fixedSize()
                        Text(what).font(.sb(11.5)).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @AppStorage(TimerStore.soundKey) private var timerSound = "Glass"

    /// The ring sound, from every sound macOS ships, with a play button to hear it.
    private var timerSoundRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").font(.sbIcon(11)).foregroundStyle(.secondary).frame(width: si(16))
            Text("Ring sound").font(PT.label)
            Spacer()
            Picker("", selection: Binding(get: { timerSound }, set: { timerSound = $0; TimerStore.preview($0) })) {
                ForEach(TimerStore.sounds, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize().sbControlSize(.small)
            Button { TimerStore.preview(timerSound) } label: { Label("Play", systemImage: "play.fill") }
                .sbControlSize(.small).help("Play \(timerSound)")
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
    }

    @AppStorage(TimerStore.ringKey) private var ringSeconds = 0

    /// How long a timer rings, as a menu beside the sound's, so the two rows read alike.
    private var ringLengthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.and.waves.left.and.right").font(.sbIcon(11)).foregroundStyle(.secondary).frame(width: si(16))
            Text("Ring for").font(PT.label)
            Spacer()
            Picker("", selection: $ringSeconds) {
                ForEach(TimerStore.ringChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize().sbControlSize(.small)
            .help("How long a timer rings before it stops on its own; Until stopped ends after an hour")
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
    }

    // ── The app: start at login, restart, quit (owner ledger K15) ───────────
    private static var agentTarget: String { "gui/\(getuid())/" + (Bundle.main.bundleIdentifier ?? "io.github.alcatraz627.switchboard") }
    @State private var loginOn = SettingsTabView.loginEnabled()

    /// On when the install's LaunchAgent is present and not disabled in launchd.
    static func loginEnabled() -> Bool {
        let id = Bundle.main.bundleIdentifier ?? "io.github.alcatraz627.switchboard"
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(id).plist") else { return false }
        let r = Services.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: 4)
        return !r.out.contains("\"\(id)\" => disabled") && !r.out.contains("\"\(id)\" => true")
    }

    private var loginRow: SystemRow {
        var r = SystemRow(label: "Start at login", state: loginOn ? .on(menuGreen) : .off,
                          note: loginOn ? "on" : "off", tip: "Switches the install's login item on or off; nothing is deleted",
                          action: {
                              _ = Services.run("/bin/launchctl", [loginOn ? "disable" : "enable", Self.agentTarget], timeout: 4)
                              loginOn = SettingsTabView.loginEnabled()
                          })
        r.icon = "power"
        r.key = "settings-login"
        return r
    }

    @State private var keepScreen = SwitchboardApp.keepScreen

    private var keepScreenRow: SystemRow {
        var r = SystemRow(label: "Keep Awake keeps the screen on", state: keepScreen ? .on(menuGreen) : .off,
                          note: keepScreen ? "on: the display stays lit" : "off: the Mac stays awake, the display may sleep",
                          tip: "Applies while Keep Awake is on",
                          action: {
                              keepScreen.toggle()
                              UserDefaults.standard.set(keepScreen, forKey: SwitchboardApp.keepScreenKey)
                              if let app = NSApp.delegate as? SwitchboardApp, app.keepAwakeOn { app.setKeepAwake(true) }
                          })
        r.icon = "display"
        r.key = "settings-keep-screen"
        return r
    }

    private var restartRow: SystemRow {
        var r = SystemRow(label: "Restart Switchboard", state: .ok, note: "", tip: "Quit and open again")
        r.icon = "arrow.clockwise"
        r.key = "settings-restart"
        r.showsBadge = false
        r.buttons = [RowButton(label: "Restart", kind: .run({
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try? p.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }), help: "Quit and open again", icon: "arrow.clockwise")]
        r.buttons[0].words = true
        return r
    }

    private var quitRow: SystemRow {
        var r = SystemRow(label: "Quit Switchboard", state: .ok, note: "", tip: "It opens again at your next login when Start at login is on")
        r.icon = "xmark.circle"
        r.key = "settings-quit"
        r.showsBadge = false
        r.buttons = [RowButton(label: "Quit", kind: .run({ DispatchQueue.main.async { NSApp.terminate(nil) }; return nil }),
                               help: "Quit Switchboard", icon: "xmark.circle", confirm: "Quit Switchboard?")]
        r.buttons[0].words = true
        return r
    }

    private var sizeRow: SystemRow {
        var r = SystemRow(label: scale.size.title, state: .ok, note: scale.size.detail, tip: "Small, Medium or Large")
        r.icon = "textformat.size"
        r.choices = UISize.allCases.map(\.title)
        r.selected = UISize.allCases.firstIndex(of: scale.size) ?? 0
        r.onChoose = { i in scale.size = UISize.allCases[i] }
        r.key = "settings-size"
        return r
    }

    @State private var watchAllowed = HotKeys.commandWatchAllowed

    private var commandWatchRow: SystemRow {
        var r = SystemRow(label: "⌘⌘ while another app is in front", state: watchAllowed ? .on(menuGreen) : .off,
                          note: watchAllowed ? "allowed" : "needs permission: click, then turn Switchboard on in Accessibility",
                          tip: "macOS only lets an app hear ⌘ on its own, from anywhere, with this permission. ⌥Space works without it.",
                          action: {
                              HotKeys.askForCommandWatch()
                              DispatchQueue.main.asyncAfter(deadline: .now() + 2) { watchAllowed = HotKeys.commandWatchAllowed }
                          })
        r.icon = "command"
        r.key = "settings-command-watch"
        return r
    }

    @State private var promptsOn = PermissionRoute.isOn
    @State private var promptsError: String?

    private var promptsRow: SystemRow {
        var r = SystemRow(label: "Answer them in Switchboard", state: promptsOn ? .on(menuGreen) : .off,
                          note: promptsError.map { "couldn't switch: \($0)" } ?? (promptsOn ? "on: prompts wait here first" : "off: the terminal asks, as usual"),
                          tip: "Holds each Claude Code permission prompt for up to \(PermissionRoute.wait) s so you can answer it from Approvals.",
                          action: {
                              promptsError = PermissionRoute.set(!promptsOn)
                              promptsOn = PermissionRoute.isOn
                          })
        r.icon = "hand.raised"
        r.key = "settings-permission-route"
        return r
    }

    private func note(_ text: String) -> some View {
        Text(text).font(PT.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group(_ title: String, note text: String, rows: [SystemRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(name: title)
            note(text)
            Card {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, PT.rowH) }
                    SystemRowView(row: row, store: store)
                }
            }
        }
    }

    /// A tab opens to "Show this tab" and one switch per section it has.
    /// While searching, only matching sections are listed and the tab opens.
    private func tabRow(_ t: SettingsTab) -> SystemRow {
        let tabOn = !store.hiddenTabs.contains(t.id)
        let sections = Visibility.sections[t.id] ?? []
        let hiddenHere = sections.filter { store.hiddenSections.contains(t.id + "::" + $0) }.count
        let note = !tabOn ? "hidden" : sections.isEmpty ? "shown"
            : hiddenHere == 0 ? (sections.count == 1 ? "its section shown" : "all \(sections.count) sections shown")
            : "\(sections.count - hiddenHere) of \(sections.count) sections shown"
        var r = SystemRow(label: t.title, state: tabOn ? .on(menuGreen) : .off, note: note, tip: "")
        r.icon = t.icon
        // A new key while searching makes the row open fresh on its matches.
        r.key = "settings-tab-" + t.id + (query.isEmpty ? "" : "-q")
        r.startsOpen = !query.isEmpty && !matches(t.title)
        var show = SystemRow(label: "Show this tab", state: tabOn ? .on(menuGreen) : .off, note: "", tip: "",
                             action: { toggle(&store.hiddenTabs, t.id) })
        show.icon = "eye"
        show.key = r.key! + "-show"
        let listed = matches(t.title) ? sections : sections.filter(matches)
        r.children = [show] + listed.map { s in
            let key = t.id + "::" + s
            var c = SystemRow(label: s, state: store.hiddenSections.contains(key) ? .off : .on(menuGreen),
                              note: "", enabled: tabOn, tip: "", action: {
                                  toggle(&store.hiddenSections, key)
                                  // A section coming back was never read while hidden: read it on the next visit.
                                  if !store.hiddenSections.contains(key) { store.catalogs[t.id] = nil }
                                  store.requestSystemRefresh()
                              })
            c.key = "settings-section-" + key
            c.icon = Icons.section[s]
            return c
        }
        return r
    }

    /// The standard macOS slider: one-second ticks, its ends labelled, the value read out beside it,
    /// and scrolling over it steps a second at a time like the panel's other sliders.
    /// The slider moves along the steps, not along seconds, so the fine end is reachable.
    private var lingerSlider: some View {
        let steps = PolicyStore.lingerSteps
        let index = Double(steps.firstIndex(of: store.hoverLinger) ?? steps.firstIndex(of: PolicyStore.defaultLinger) ?? 0)
        return HStack(spacing: 10) {
            Slider(value: Binding(get: { index }, set: { store.hoverLinger = steps[Int($0.rounded())] }),
                   in: 0...Double(steps.count - 1), step: 1) {
                Text("Mouse-away delay")
            } minimumValueLabel: {
                Text("now").font(PT.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("15 s").font(PT.caption).foregroundStyle(.secondary)
            }
            .labelsHidden().sbControlSize(.small)
            Text(store.hoverLinger == 0 ? "0 s" : String(format: store.hoverLinger < 1 ? "%.2f s" : "%.1f s", store.hoverLinger))
                .font(PT.label.monospacedDigit()).frame(width: sw(44), alignment: .trailing)
        }
        .padding(.horizontal, PT.rowH).padding(.vertical, PT.rowV + 2)
        .scrollSteps("settings.linger", inContent: true, stepper: .slider()) { by in
            let i = min(steps.count - 1, max(0, Int(index) - by))
            store.hoverLinger = steps[i]
        }
    }

    /// Every hover page in the owner's order, shown or not.
    private var quickPages: [SettingsTab] {
        store.quickPageOrder.compactMap(QuickPage.init(rawValue:)).map { SettingsTab(id: $0.rawValue, title: $0.title, icon: $0.icon) }
    }

    /// A page's switch; the last page shown cannot be hidden, so the card always has one.
    private func pageRow(_ p: SettingsTab) -> SystemRow {
        let on = !store.hiddenQuickPages.contains(p.id)
        let last = on && store.shownQuickPages == [p.id]
        var r = SystemRow(label: p.title, state: on ? .on(menuGreen) : .off,
                          note: last ? "the only page shown" : "", enabled: !last, tip: "",
                          action: { if !last { toggle(&store.hiddenQuickPages, p.id) } })
        r.icon = p.icon
        r.key = "settings-page-" + p.id
        return r
    }

    private func hoverRow(_ item: HoverItem) -> SystemRow {
        var r = SystemRow(label: item.title, state: store.hoverItems.contains(item) ? .on(menuGreen) : .off,
                          note: item.detail, tip: "", action: {
                              if store.hoverItems.contains(item) { store.hoverItems.remove(item) } else { store.hoverItems.insert(item) }
                          })
        r.key = "settings-hover-" + item.rawValue
        return r
    }

    @ObservedObject private var sync = NotesSync.shared

    /// The Pi's repository the notes folder syncs with; empty keeps history local only.
    private var notesRemoteRow: SystemRow {
        let remote = sync.remote
        let when = sync.lastSync.map { "synced " + age($0) } ?? "not synced yet"
        var r = SystemRow(label: remote.isEmpty ? "No sync remote" : remote,
                          state: sync.problem == nil && !remote.isEmpty ? .ok : .off,
                          note: remote.isEmpty ? "every save is still kept as a version here" : (sync.problem ?? when)
                              + (sync.conflicts > 0 ? " · \(sync.conflicts) note\(sync.conflicts == 1 ? "" : "s") with both sides" : ""),
                          tip: "A git remote on the Pi, user@host:Notes.git. Saves commit here; the Pi's edits come in on a timer.")
        r.key = "settings-notes-remote"
        r.showsBadge = false
        r.labelIsName = true
        r.buttons = [RowButton(label: "Set remote", kind: .ask(placeholder: "user@host:Notes", { line in
            UserDefaults.standard.set(line.trimmingCharacters(in: .whitespaces), forKey: NotesSync.remoteKey)
            DispatchQueue.main.async { NotesSync.shared.sync(); store.objectWillChange.send() }
            return nil
        }), help: "Set the remote and sync now", icon: "arrow.triangle.2.circlepath")]
        if !remote.isEmpty {
            r.buttons.append(RowButton(label: "Sync", kind: .run({ DispatchQueue.main.async { NotesSync.shared.sync() }; return nil }),
                                       help: "Pull the Pi's edits and push yours now", icon: "arrow.clockwise"))
        }
        for i in r.buttons.indices { r.buttons[i].words = true }
        return r
    }

    /// Choose a folder for notes; existing notes stay where they are, so a
    /// move is a Finder job the owner does on purpose.
    private var notesFolderRow: SystemRow {
        let custom = UserDefaults.standard.string(forKey: NotesStore.folderKey)?.isEmpty == false
        var r = SystemRow(label: abbreviateHome(NotesStore.dir), state: .off,
                          note: custom ? "chosen by you; notes already saved elsewhere stay there" : "the default", tip: "")
        r.key = "settings-notes-folder"
        r.showsBadge = false
        r.buttons = [RowButton(label: "Choose", kind: .run({
            DispatchQueue.main.async {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.prompt = "Use this folder"
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let url = p.url {
                    UserDefaults.standard.set(url.path, forKey: NotesStore.folderKey)
                    NotesStore.shared.load()
                    store.objectWillChange.send()
                }
            }
            return nil
        }), help: "Choose another folder for notes", icon: "folder.badge.gearshape", words: true)]
        if custom {
            r.buttons.append(RowButton(label: "Reset", kind: .run({
                DispatchQueue.main.async {
                    UserDefaults.standard.removeObject(forKey: NotesStore.folderKey)
                    NotesStore.shared.load()
                    store.objectWillChange.send()
                }
                return nil
            }), help: "Go back to the default folder", icon: "arrow.uturn.backward", words: true))
        }
        return r
    }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }
}
