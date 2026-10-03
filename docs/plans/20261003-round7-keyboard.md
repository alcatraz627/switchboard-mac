# Round 7: Switchboard by keyboard

> "I do not like using the mouse when in the flow so when there is a need to do it but the keyboard support isn't great I just end up using it less." Notes are P1; bulbs and reminders are P2; the other tabs only need it if it falls out of the same work.

Repo at 2026-10-03, after the desk panel fix. No keyboard code is built yet.

## The mental model, and what it missed

The app was built pointer first. Keyboard support exists only inside text fields (Return, Escape, ⌘↩ in a few places, `NotesView.swift:60`), so the keyboard can type but cannot move. Four things follow from that, and they explain every item in the batch:

1. **There is no "where am I".** No row, section or tab can hold focus. So arrows do nothing, Tab only walks text fields, and Escape has nowhere to go (it just drops focus).
2. **Saving belongs to a button.** The compose bar's ⌘↩ is attached to an icon button, so it only fires when SwiftUI routes the shortcut to it. In practice the owner reaches for the mouse. A saved note also loses the keyboard, so writing a second line means clicking again.
3. **Reading and editing are one state.** Clicking a note opens the editor straight away. There is no state where a note is open to read, select and copy without the risk of typing into it.
4. **The app has no front door.** It opens only from the menu-bar icon, so every visit starts with the mouse.

The updated model: **every surface has a focus that the keyboard owns.** Focus sits at one of four depths (tab, zone, row, field), arrows move within a depth, Return or → goes one deeper, Escape or ← comes one back up. Typing only happens at the deepest depth. Every action a button offers has a key at the depth where the button is visible.

## Getting in: the front door

**Recommended: a leader key plus three direct chords.**

- **⌘⌘** (tap Command twice) opens the panel on the tab last used. You land on Notes if Notes was last, as you asked. While the panel is open, a single letter jumps to a tab: **N** Notes, **U** Usage, **B** Bulbs, **T** Timers, **R** Reminders, **S** Sessions, **A** Approvals. ⌘⌘ again, or Escape at the top depth, closes it.
- **⌃⌥⌘N**, **⌃⌥⌘U**, **⌃⌥⌘B** open Notes, Usage and Bulbs directly from anywhere.

Why both: the leader needs only one global key and its letters can never clash with another app, because they exist only while the panel is open. The three chords skip a step for the surfaces you named. Hyper-style chords (⌃⌥⌘) are rarely taken by other apps.

Things to know:

- Double-tapping ⌘ needs macOS **Input Monitoring** permission, because the app has to watch modifier keys system-wide. The three chords need no permission (they use the system hotkey API). If you turn the permission down, ⌃⌥⌘Space becomes the leader instead.
- macOS can bind "Press either Command key twice" to Siri. If yours does, the two would fight. I'll check this setting at build time and say if it is set.
- Alternatives I considered: chords only (stable, but seven global combinations to remember), or the leader only (one thing to learn, but always two keystrokes). Settings will let you change every key.

## Inside the panel: one grammar for every tab

| Key | Tab bar | Zone or list (row focused) | Open row (reading) | Field (typing) |
|---|---|---|---|---|
| ←/→ | previous/next tab | → or Return opens the row; ← closes it | ↑/↓ move between title and body; → or Return starts typing there; ← closes the row | moves the cursor |
| ↑/↓ | into the tab | previous/next row, crossing zones | between blocks | moves the cursor |
| Tab / ⇧Tab | next zone | next zone (compose, filter, list) | next block | next field |
| Escape | closes the panel | back to the tab bar | closes the row, focus stays on it | stops typing, saves, stays on the block |
| ⌘1 to ⌘9 | jump to a tab | same | same | same |

A focused row shows a ring, the same accent the reveal flash uses, so you always know where the keyboard is.

## Notes (P1), the full set

**Compose (the new note at the top)**

- Typing starts in the title. Shift+Return opens the body (kept as it is now).
- **⌘↩ saves** if there is text, from the title or the body. The new note then opens in the list in typing mode, with the cursor in the same field and position. You carry on writing in the saved note.
- **Escape** leaves the compose area without discarding anything. The draft stays in the box and comes back next time you open the panel.
- ↓ from the compose area goes to the colour filter, then to the list.

**Colour filter (new, one small row under compose)**

- One dot per colour plus "all". ←/→ moves along it, Space or Return toggles a colour. More than one colour can be on. The list shows only matching notes, and the row says how many are hidden.

**A note in the list**

- ↑/↓ moves between notes. The list scrolls to keep the focused note in view.
- **→ or Return** opens the note for reading. Nothing is editable yet.
- In a note open for reading, **↑/↓** moves between the title block and the body block. **⌘A** selects the focused block, **⌘C** copies it (or the selection), **⇧⌘C** copies title and body together.
- **→ or Return again** starts typing in the focused block, with the cursor at the end.
- While typing, **Escape** stops typing and saves, and the note stays open for reading. **← or Escape** again closes the note.
- **⌘↩** while typing saves at once and keeps typing (it already saves 0.7 s after you stop typing; this makes it explicit).
- Single keys on a focused note that is not being typed in: **P** pins or unpins, **C** copies title and body, **1 to 6** sets a colour, **⌫** deletes (with the same confirm).

## Bulbs and reminders (P2), same grammar

- **Bulbs:** ↑/↓ moves between bulbs, Space switches the focused one on or off, ←/→ steps brightness in the same direction as the wheel, Return opens its colour strip, and ←/→ then picks a colour.
- **Reminders:** the Notes list rules, minus compose: ↑/↓, → to read, → again to edit the title, Space to tick done.
- Other tabs get the general grammar (tabs, zones, rows, Return to open) for free, with no tab-specific keys.

## Already done this turn

- **Desk panels** now behave like ordinary windows. They used to sit on the desktop layer, so every window covered them and a click could not raise them. Now a click brings one forward, the stack button keeps it above every window, and the white title strip is gone (commit "Desk panels behave like windows").
- **The hub on your phone:** it was stopped in pm2, so the tailnet URL was dead. It is running again at http://aakarshs-m5-pro.tail905820.ts.net:5400/ and set to come back after a restart. The csync plan is noted in `docs/roadmap.md`.
- **The animation direction** has your approval recorded in its memo.

## Build order and checks

1. The focus engine (depths, ring, arrows, Escape, Tab) as one shared component, and Notes on it. Check: a probe walks the Notes tab with key events only (compose, save, filter, open, read, copy, edit, Escape) and asserts focus and clipboard after each step; a screenshot shows the ring.
2. Front door: leader and chords, the permission check, and the Siri conflict check. Check: an event sent to the open panel switches tabs; the chord opens the panel when another app is in front.
3. Bulbs and reminders on the same engine.
4. The animation build (P1 to P6 of the memo), after this, so motion lands on the new focus ring as well.
