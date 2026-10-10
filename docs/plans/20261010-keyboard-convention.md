# Switchboard key-map convention

For the owner as a power user who peruses (GLOSSARY.md:75-77): keys are shown in place, hinted when held, and findable in a palette. No sequence has to be remembered. This extends round 7; it changes none of it.

## Grammar in force (round 7, built)

1. Focus sits at one of four depths: tab, zone, row, field (`docs/plans/20261003-round7-keyboard.md:16`).
2. Arrows move within a depth; Return or → goes one deeper; Escape or ← comes back up. Typing happens only at the deepest depth (`Sources/Keys.swift:2-4`).
3. A ring shows where the keyboard is. One open note and one colour strip at a time (`round7:43`, `round7:81`).
4. Panel-wide: ⌘⌘ opens (again shows a letter per tab, third time closes), ⌃⌥⌘N/U/B/Space open from anywhere, ⌃Tab walks tabs, ⌘1 to ⌘5 pick a space (`round7:83`).
5. Row keys exist only on Notes, Timers and Home. Keys are not yet remappable (`round7:83-84`).

## Discoverability rules

1. **Palette lists every action with its key.** One chord opens it, ⇧⌘P (VS Code's palette chord, https://code.visualstudio.com/docs/getstarted/userinterface). Filtering by name or by key is the VS Code keybindings editor behaviour (https://code.visualstudio.com/docs/configure/keybindings). The user-interface page says the palette carries shortcuts "for the most common operations"; showing the key beside each row is our choice, not confirmed there.
2. **Palette also jumps.** It lists tabs, notes and timers as "go to" rows, so it doubles as tab search. Chrome's tab search is ⇧⌘A (https://www.computerhope.com/shortcut/chrome.htm; Chrome's own help page https://support.google.com/chrome/answer/157179 does not list it). Bind ⇧⌘A to the palette pre-filtered to "go to".
3. **Hold ⌘ for about one second to see the hints for the current depth.** A small overlay lists the keys live at that depth. This is CheatSheet's behaviour (https://www.igeeksblog.com/view-mac-apps-keyboard-shortcuts-with-cheatsheet/). It must not collide with the ⌘⌘ double tap: the hint needs a hold, the leader needs two taps.
4. **Hold ⇧, ⌥ or ⌃ to light only the keys that use it.** KeyCue's behaviour (https://www.macworld.com/article/217986/cheatsheet_helps_you_find_and_remember_keyboard_shortcuts.html).
5. **Tab keys follow Chrome.** ⌘⌥← and ⌘⌥→ for previous and next tab, ⌘1 to ⌘8 for tab N, ⌘9 for the last (https://support.google.com/chrome/answer/157179). Round 7 uses ⌘1 to ⌘5 for spaces, so inside a space ⌘1 to ⌘8 would pick its tab and spaces move to ⌃1 to ⌃5. Decision for the build, flagged in the table below.
6. **⌘L and ⌘F both put the cursor in the tab's filter box.** Chrome's ⌘L moves to the one text box that matters (https://support.google.com/chrome/answer/157179). A tab with no filter shows the hint "no filter here" instead of doing nothing.
7. **Chords show their pending state.** VS Code defines a chord as two keypresses separated by a space (https://code.visualstudio.com/docs/configure/keybindings). The only chord here is the ⌘⌘ leader, which already shows its letters; show the same pill for any later chord, and never add one without a palette row.
8. **Hyper works without extra setup.** Karabiner's Hyper is ⌘⌥⌃⇧ held together (https://karabiner.ts.evanliu.dev/examples/modifier-keys/caps_lock-to-hyper). Round 7's global chords are ⌃⌥⌘ without ⇧, so a Caps Lock Hyper user would miss them. Accept each global chord with or without ⇧. This is derived from the two sources, not tested.

Not sourced: a `?` cheat-sheet key. No source for any of the four apps confirmed one. Use `?` as an alias that opens the palette filtered to the current depth; treat it as our convention.

1Piece: the only source found (https://alternativeto.net/software/1piece/) describes a window list, Hot Corner space switching and window resizing. No hint overlay was found, so no rule here cites it.

## Key map

Panel-wide keys apply on every row below: ⌘⌘ leader, ⌃Tab, ⇧⌘P palette, ⇧⌘A go to, ⌘L/⌘F filter, hold ⌘ for hints, Escape up one depth. "R7" means round 7 already built it. Generic row keys (new, all tabs): ↑/↓ move, Return or → opens detail, Space flips the row's switch if it has one, ⌘C copies the row's id, shown beside the action it fires.

| Surface | Panel-wide keys | Row keys needed | Status |
|---|---|---|---|
| Agents | yes | Space allows or blocks a permission; Return opens its rule | panel keys R7; rows new |
| Usage | yes | none beyond generic (read only); ←/→ pages Claude/Codex limits | panel keys R7; rows new |
| Claude MCP | yes | Space enables or disables a server | panel keys R7; rows new |
| Hooks | yes | Space enables or disables a hook; Return shows its output | panel keys R7; rows new |
| Library | yes | Return opens an item; ⌘C copies its path | panel keys R7; rows new |
| Ledger | yes | Return opens an entry; ⌘C copies its id | panel keys R7; rows new |
| Queue | yes | Return opens; ⌫ removes with confirm | panel keys R7; rows new |
| Notes | yes | full set | R7 complete |
| Timers | yes | full set (Return renames, + adds a minute, ⌫ clears) | R7 complete |
| Machine | yes | Space flips Keep Awake; Return opens a drive or repo | panel keys R7; rows new |
| Runtime | yes | Return opens a service; start, stop and restart are palette rows, not single keys | panel keys R7; rows new |
| Controls | yes | Space flips Wi-Fi or Bluetooth; ←/→ moves sound and screen sliders | panel keys R7; rows new |
| Home | yes | full set (Space, ←/→, ⇧←/⇧→, Return, 1 to 8) | R7 complete |
| Remote | yes | Return connects or opens the machine | panel keys R7; rows new |
| Approvals | yes | ⌘↩ allows the focused request, ⌫ denies; both labelled on their buttons | panel keys R7 (header button reachable by Tab); rows new |
| Settings | yes | Settings > Keyboard lists the keys (R7); add the palette and hints to that list; Space flips a switch | partly R7 |
| Hover card | none: it opens on pointer rest | ←/→ along the launcher, Return opens that tab, Escape closes | new |
| Detached widget | yes, while it has the keyboard | the same row keys as its source tab; ⌘W closes, ⌃Tab stays inside it | new |

## Rulings (owner, decision page session1-notes-keyboard, 2026-10-10)

- **⌘1 to ⌘5 stay on spaces; ⌘⌥←/→ and the palette walk tabs.** Owner's note, binding: "Win + Num is already used by so many apps like ghostty or vscode or all browsers; if it can fire reliably when switchboard is in focus (even in hover state) but not misfire into another app then that's fine. Shift + Num just types chars and is used, esp as a software engineer. Don't make me move my fingers too much for related actions like tab vs subtabs vs items within." So: ⌘N is a panel-local key, never global; it must work while the hover card has focus; never a ⇧+digit binding anywhere; and tab, sub-tab and row moves sit on neighbouring keys (⌘⌥←/→ for tabs, ←/→ for sub-tabs inside a tab, ↑/↓ for rows) so one hand position covers all three. Probe: a synthetic ⌘2 with another app frontmost does nothing; the same key with the hover card focused switches the space.
- **Approvals by key are two-step: Return opens, ⌘↩ confirms.** Owner's note, binding: "as long as I can reach the switchboard, focus the intended approval, approve, and close and go back with focus to the previous app all from keyboard with my hand where it is." So the full path is one chord to open (⌘⌘ or ⌃⌥⌘A), the Approvals tab lands with the first waiting request focused, Return opens it, ⌘↩ confirms, and Escape closes the panel and returns focus to the app that had it. Probe: drive that sequence with synthetic keys from a scratch approval file and assert the push-gate file is written and the previous app is frontmost again.

## Built 2026-10-10 (gcc-reaper)

- `Sources/Actions.swift`: the action table, the palette (⇧⌘P all, ⇧⌘A places, ⌘/ keys here), the hold-⌘ hint strip, `probeActions()` in `--probe-quick`, and `--snapshot … --palette | --hints` for pictures.
- Panel keys added: ⌘⌥←/→ tabs within a space, ⌘D pin, ⌘R reload, ⌘, Settings, ⌘L / ⌘F search box (a tab without one says so).
- Row keys were already on every SystemTabView tab (Agents, MCP, Hooks, Library, Ledger, Queue, Machine, Runtime, Remote, Approvals, Settings) via `.keyRow`; added to Controls (mute, Wi-Fi, Bluetooth, devices on Space; volume and brightness on ←/→). Usage's bars stay read-only; its thresholds are policy rows and already take keys.
- Approvals two-step: Return opens, ⌘↩ allows, ⌫ denies, both refused while the request is closed (`RowKeyActions.confirm/deny`). Escape at the top returns the keyboard to the app that had it (`cameFrom`).
- Global chords register with and without ⇧; ⌘1 to ⌘5 on the hover card open that space.
- Not built here: a palette inside detached widgets (they already take every row key), remappable keys in Settings, the widget window model (owner review A first).

## Build first

1. **Palette plus hold-⌘ hints, fed from one action registry.** Each action is registered once with its title, key, surface and depth; the palette and the hint overlay both read it, so they cannot disagree. Probe: a test walks the registry and fails if any bound key in `Keys.swift` has no registry row, then opens the palette with a synthetic ⇧⌘P and asserts every row shows its key.
2. **Generic row keys on all remaining tabs** (↑/↓, Return, Space, ⌘C). Probe: extend `--drive-notes` into a drive that visits each tab in the table with key events only and asserts focus moves, a detail opens, and the clipboard holds the id after ⌘C.
3. **Detached widgets take the same keys, and ⇧ is optional on global chords.** Probe: send ⌃⌥⌘N and ⌃⌥⌘⇧N and assert both open Notes; send ↓, Return, Escape to a detached widget and assert it ends at the depth it started.

## Sources

- https://code.visualstudio.com/docs/getstarted/userinterface (palette opens with ⇧⌘P)
- https://code.visualstudio.com/docs/configure/keybindings (keybinding search, chord definition)
- https://support.google.com/chrome/answer/157179 (Mac tab and address bar keys)
- https://www.computerhope.com/shortcut/chrome.htm (tab search)
- https://www.igeeksblog.com/view-mac-apps-keyboard-shortcuts-with-cheatsheet/ and https://www.macworld.com/article/217986/cheatsheet_helps_you_find_and_remember_keyboard_shortcuts.html (hold-⌘ overlay, modifier highlight)
- https://karabiner.ts.evanliu.dev/examples/modifier-keys/caps_lock-to-hyper (Hyper)
- https://alternativeto.net/software/1piece/ (1Piece description only)
- Local: `docs/plans/20261003-round7-keyboard.md`, `Sources/Keys.swift:1-140`, `~/.claude/GLOSSARY.md:75-77`, `README.md:156-169`
