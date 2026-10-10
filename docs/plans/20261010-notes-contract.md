# The notes store: one folder, every device, nothing lost

<!-- sessions: gcc-reaper@2026-10-10 -->

Owner, 2026-10-10: "I don't wanna lose my notes if one device goes off"; "dead
simple merge reconcile, avoid losing anything"; "I want quick speed and I care
not as much about precise merge conflict resolution"; the Pi agent "can view and
create and modify notes as well; same note space, but it always leaves a tag for
agent-created notes."

This page is the contract the three apps build against. It is short on purpose.
Segment G1 in `~/.claude/assets/reports/20261010-gcc-fix-list/work-segments.md`.

## What exists today

| Where | Store | Shape | Code |
|---|---|---|---|
| Mac, Switchboard | a folder of `<id>.md`, path chosen in Settings | frontmatter (title, created, tags, expires, remind_at, remind_repeat, reminder_id, pinned, color) then the body | `Sources/Notes.swift:345-400` |
| Pi, csync media server | SQLite `notes` and `pins` tables, images and files per note | title, body, revision, created_at, updated_at; pins carry url, description, content, tags, a file | `csync/media/server.py:118-230, 374-432` |
| Phone, csync app | talks to the Pi over `/v1/notes` and `/v1/pins`, revision-checked saves | same as the Pi | `csync-hub/app` |

The Switchboard order (`order.json`) is already kept outside a folder the owner
chose (`Notes.swift:213-218`), so a shared folder never carries Mac-only state.

## The contract

```
   Mac ~/Notes (git clone) ──push/pull──> Pi ~/Notes.git (bare) <──commit── Pi ~/Notes (clone)
        │                                                                     │
   Switchboard reads/writes files                            csync server reads/writes files
   commits on save, syncs on a timer                         Pi agent writes files, tag agent: pi
                                                                              │
                                                             phone <── /v1/notes over HTTP ──>
                                                             local cache, revision-checked save
```

1. **One folder of markdown is the store.** `~/Notes/` on the Mac, `~/Notes/` on
   the Pi. One file per note, `<id>.md`, Switchboard's frontmatter as it is
   today plus three fields: `agent: <name>` on any note an agent created or last
   edited (never removed by a human edit, so provenance stays), `source: csync`
   on imported notes, `url:` on a pin. Attachments live in `attachments/<id>/`.
2. **Git is the sync, the history and the backup.** The Mac and the Pi are
   clones; the Pi also holds the bare remote. Switchboard commits a note on save
   (debounced to the existing 0.7 s) and pulls then pushes on a timer and on
   panel open, only when the Pi answers; otherwise it works on its copy and
   catches up later. The Pi commits what the phone and the agent write. History
   is `git log -- <id>.md`; a note's history view is that list. A nightly
   mirror to a private GitHub repo rides the weekly reap job (G4.3) for the
   off-site copy.
3. **A conflict keeps both and never blocks.** Merge is non-interactive. When
   both sides changed the same note, git's markers stay in the file and the
   commit lands; Switchboard and the phone show a conflict badge on that note,
   and the owner edits it when they like. Nothing is ever discarded, and no
   sync stops waiting for a human. Frontmatter conflicts resolve to the newer
   `modified` automatically so the badge is about the body only.
4. **The phone stays on the API.** No git on Android. csync keeps its local
   cache, saves with the revision check it has today (revision becomes the file's
   last commit hash), and on a stale revision the Pi writes the phone's version
   as the conflict side of the same file rather than refusing. Offline edits
   queue and replay in order.
5. **Pins become notes.** A pin is a note with `url:` and the tag `pin`; its
   file goes to `attachments/`. One list, one sync, and "pin a link from the
   phone onto the laptop" (G4.1) is just a note arriving.
6. **The Pi agent is a peer, not a special case.** It reads and writes the
   folder directly and commits. Every note it creates or edits carries
   `agent: pi` (any other agent writes its own name). Switchboard and csync
   show the agent tag as a small mark on the row.
7. **Reminders live in the file.** `remind_at` and `remind_repeat` are the
   truth; each device creates and clears its own native reminder from them
   (macOS Reminders today, csync's native reminders on the phone). Ringing,
   persistence and cross-device creation are segment G3 and change nothing here.
8. **Order, filters and drafts are per device.** `order.json`, colour filters
   and the compose draft stay in each app's own state, as Switchboard does now.

## One-time import

The Pi's SQLite notes and pins (the "mostly junk" set) are exported to the folder
once with `source: csync`, attachments moved alongside, and a review list written
to `~/Notes/.import/review.md` (title, date, size, first line) so the owner can
skim and delete. No duplicate detection beyond identical title and body, since
the owner says there are no real duplicates. Switchboard's current folder moves
to `~/Notes/` with its order file left where it is.

## What each app changes

| App | Change | Check |
|---|---|---|
| Switchboard | default folder `~/Notes`; commit on save; pull/push on timer and panel open; conflict badge; history view from `git log`; agent mark on rows; `url:` and `source:` round-trip | `--probe-notes` grows: commit after save, pull merges a Pi-side edit, conflict file gets the badge, agent tag survives an owner edit |
| csync server (Pi) | `notes` and `pins` read and write the folder, not SQLite; commit per write; revision = commit hash; stale save writes the conflict side; import script | `tests/test_media_service.py` runs on a scratch repo; a stale PUT yields a file with both bodies and 200 |
| csync app | no change to the API shape; conflict badge; agent mark; pins list reads notes tagged `pin` | one smoke on the emulator per list |
| Pi agent | a `notes` tool: list, read, write with `agent: pi`, commit | one note created by the agent appears on the Mac with the mark |

## Rulings (owner, decision page session1-notes-keyboard, 2026-10-10)

1. Sync by git on Mac and Pi, phone on the API: **yes**. Owner's note, binding:
   "Just ensure they work on all devices, do not cause reconcile issues, and
   allow for quick updation (debounce based)." So the Mac commits on the
   existing 0.7 s save debounce and syncs on a short timer (target: a note is
   on the other device within a minute), and the merge path is exercised on all
   three devices before it is called done.
2. Conflicts as git markers inside the one file, badge on the row: **yes**.
3. Pins fold into notes: **yes**. Owner's note: "Pins are essentially notes with
   more dressing; the title + body + url to click / copy (all optional, need at
   least one to make a pin). Feel free to change the model of the pins, I
   haven't used them seriously." So a pin is a note where any of title, body,
   `url:` may be empty but not all three; the row shows the url as a click and
   a copy affordance.

## Out of this page

Ringing reminders (G3), one-gesture capture (G2), comments on plan docs (G8),
the editor itself (G1.4, gets a mock round first).
