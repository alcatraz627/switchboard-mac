# How Switchboard is put together

Switchboard is one menu bar icon (three faders) that opens a panel. Each tab in
the panel is a **concern**: one question about this Mac, answered with the
switches for it. There is no server and no daemon; the app reads files and runs
small helper scripts when the panel opens or a switch is flipped.

```
 Switchboard.app
 ┌──────────────────────────────────────────────────────────────────────┐
 │ main.swift        entry; headless flags (--dump, --snapshot, …)      │
 │ App.swift         the snapshot, Machine rows, Keep Awake, timed flips│
 │ PolicyPanel.swift the popover, space bar, SwitchboardConcerns list   │
 │  ├─ Agents     Policy.swift     ──▶ pol.sh (optional, ~/.claude)     │
 │  ├─ Usage      Usage.swift      ──▶ rate-limit files, Codex gate     │
 │  ├─ Hooks, Ledger, Queue, Library, Claude MCP                        │
 │  │             Catalog.swift + CatalogReaders.swift ──▶ ~/.claude    │
 │  ├─ Notes      Notes.swift, NotesView.swift ──▶ .md files, Reminders │
 │  ├─ Timers     Timers.swift     ──▶ sound, UserNotifications         │
 │  ├─ Runtime, Machine, Remote   App.swift + Switchboard.swift         │
 │  │             ──▶ Resources/lib/*.py (jobs, devservers, gitscan, …) │
 │  ├─ Controls   Controls.swift   ──▶ CoreAudio, IOBluetooth           │
 │  ├─ Home       Lights.swift     ──▶ Resources/lib/wiz.py (UDP 38899) │
 │  ├─ Settings   Settings.swift   ──▶ Visibility (AppSupport.swift)    │
 │  └─ Approvals  Needs.swift      ──▶ push nonces, policy asks         │
 │ Hover.swift       the preview on the menu bar icon                   │
 │ WhenPicker.swift  one time picker for every "until" and "remind at"  │
 │ Reorder.swift     drag to reorder (notes, timers, bulbs)             │
 │ States.swift      pending, failure and reading-age lines             │
 │ AppSupport.swift  paths, log, live Claude sessions, Integrations     │
 │ DesignKit.swift + Palette.swift   the shared look (design-kit.md)    │
 └──────────────────────────────────────────────────────────────────────┘
```

### The snapshot

The Machine, Runtime, Remote and Approvals tabs read one **snapshot**: every
helper script run side by side off the main thread, plus a few file and
network checks. Requests made together (opening the panel asks from four tabs)
share one snapshot. A caller that waits on it, such as a switch confirming its
flip, always gets its answer from a snapshot that started after it asked, so a
slow helper makes a confirmation late, never wrong. `--probe-snapshot` checks
both.

The list tabs (Hooks, Ledger, Queue, Library, Claude MCP) read their own
sections through the catalog engine instead, one read per tab, on open.

## Where things live

| What | Where |
|---|---|
| The app | `~/Applications/Switchboard.app` after `scripts/build.sh --install` |
| Python helpers | inside the bundle, `Contents/Resources/lib` |
| Saved devices, bulb names | `~/Library/Application Support/Switchboard/` |
| Notes | `~/Library/Application Support/Switchboard/notes/`, one `.md` each, or the folder chosen in Settings |
| Preferences (thresholds, last tab, timers, hidden tabs) | macOS defaults, `io.github.alcatraz627.switchboard` |
| Log | `~/Library/Logs/Switchboard/switchboard.log` (1 MB, one backup) |
| Start at login | `~/Library/LaunchAgents/io.github.alcatraz627.switchboard.plist` |

Two environment variables exist for tests and development only:
`SWITCHBOARD_LIB` points at a helpers folder (the source tree), and
`SWITCHBOARD_STATE` points at a state folder. Both are read in one place each:
`AppPaths` in `AppSupport.swift` and `state.py`.

## Optional integrations

Switchboard started life inside a personal Claude Code setup (`~/.claude`),
and several rows drive tools from that setup. Each one is checked for at
runtime in `Integrations` (`AppSupport.swift`); when the tool is missing its
row or tab is hidden, never shown broken.

| Row or tab | Needs | Without it |
|---|---|---|
| Agents tab | `~/.claude/scripts/pol/pol.sh` and a policy registry | tab hidden |
| Usage, Claude bars | `~/.claude/widgets/.rate-limits-raw.json` (written by a statusline) | "No usage reading yet" |
| Usage, Codex bars | `~/.claude/adapters/codex/bin/codex-usage-gate.py` | "No Codex reading yet" |
| Guards: muted guards | hook scripts under `~/.claude/scripts/hooks`, `scripts/cron`, `adapters/*` | row hidden |
| Guards: permission prompts | Claude Code's `~/.claude/settings.json` | row hidden |
| Guards: push approvals | `.push-approved-<session>` files, live sessions from `~/.claude/sessions` | row hidden |
| Kanban Board | `~/.claude/scripts/kanban/server.ts`, pm2, bun | row hidden |
| Session Hub | the claude-instances app's `lib/hub.sh` | row hidden |
| ipc Broker | `claude-ipc` on the login PATH | row hidden |
| Decision Pages | a pm2 process named `decision-pages` | row hidden |
| Warden, Board sync | their scripts under `~/.claude` | row hidden |

Everything else (Keep Awake, schedules, wake-on-LAN, WiZ bulbs) needs nothing
but macOS and python3.

## The one rule for switches

A click may restore a protection, never remove one. Re-arming a muted guard
deletes its mute file; muting stays a deliberate act in a shell. Revoking a
stale push approval is one click. The only switch that weakens a safeguard,
suppressing a Claude Code permission prompt, asks first in a modal.

## Timed flips

Any plain on/off row can be flipped for a while ("Keep Awake for 2 hours").
The timer is saved in preferences, so a restart keeps it. When it is due the
row is re-read first, and it is flipped back only if it is not already where
it should be, so a change you made by hand in between is never undone twice.
A switch whose section is hidden in Settings still keeps its timer: while any
timer is pending, the snapshot reads the hidden sections it could belong to.
`--probe-timers` exercises all of this on the real Keep Awake switch and reads
the power assertion back from `pmset`.

## Permissions

Switchboard asks for Bluetooth (Controls) and Reminders (Notes) the first time
it needs them, never at launch. macOS files a grant under the app's code
requirement. `scripts/build.sh` signs ad hoc with a requirement that names the
bundle id, so a grant survives a rebuild; the cost is that any local build
signed with that id gets the same grants. Notifications are separate: when
macOS has them off for Switchboard, the Timers tab says so, and a timer still
rings.

## Headless checks

Every surface can be checked without a screen:

```
Switchboard --dump                        Machine tab rows as text
Switchboard --dump-policy [--scope DIR]   Agents tab rows as text
Switchboard --snapshot out.png --tab usage [--light] [--expand]
Switchboard --snapshot-quick out.png --page home|limits|approvals|bulbs|notes|timers|controls|models   one hover page
Switchboard --snapshot-when out.png       the time picker
Switchboard --probe-timers                timed-flip engine (flips Keep Awake, restores it)
Switchboard --probe-snapshot              one snapshot per burst; a wait gets a fresh one
Switchboard --probe-catalog               list tabs: parsing, failure, search, redaction, toggles
Switchboard --probe-notes                 notes files, reminders (a stand-in), hand-written files
Switchboard --probe-timers-tab            countdowns, the repeating chime, silencing
Switchboard --probe-visibility            hidden sections are neither drawn nor read
Switchboard --probe-approve | --probe-shell | --probe-transcript | --probe-controls
```

The probes that write use a scratch folder or a probe-only preference key,
never your notes, timers or `~/.claude`. `tests/run-tests.sh` runs them all.

`scripts/snapshots.sh` renders every tab in both appearances.

## Talking to other apps

- `dev.switchboard.toggle` (distributed notification) opens or closes the
  panel. The claude-instances dropdown uses it.
