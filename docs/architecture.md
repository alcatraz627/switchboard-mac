# How Switchboard is put together

Switchboard is one menu bar icon (three faders) that opens a panel. Each tab in
the panel is a **concern**: one question about this Mac, answered with the
switches for it. There is no server and no daemon; the app reads files and runs
small helper scripts when the panel opens or a switch is flipped.

```
 Switchboard.app
 ┌──────────────────────────────────────────────────────────────────────┐
 │ main.swift        entry; headless flags (--dump, --snapshot, …)      │
 │ App.swift         Machine tab rows, Keep Awake, timed flips, kanban  │
 │ PolicyPanel.swift the popover, tab bar, SwitchboardConcerns registry │
 │  ├─ Agents   Policy.swift      ──▶ pol.sh (optional, ~/.claude)      │
 │  ├─ Usage    Usage.swift       ──▶ rate-limit files, Codex gate      │
 │  ├─ Machine  App.swift + Switchboard.swift                           │
 │  │                             ──▶ Resources/lib/jobs.py, wol.py     │
 │  └─ Home     Lights.swift      ──▶ Resources/lib/wiz.py (UDP 38899)  │
 │ AppSupport.swift  paths, log, live Claude sessions, Integrations     │
 │ DesignKit.swift + Palette.swift   the shared look (design-kit.md)    │
 └──────────────────────────────────────────────────────────────────────┘
```

## Where things live

| What | Where |
|---|---|
| The app | `~/Applications/Switchboard.app` after `scripts/build.sh --install` |
| Python helpers | inside the bundle, `Contents/Resources/lib` |
| Saved devices, bulb names | `~/Library/Application Support/Switchboard/` |
| Preferences (thresholds, last tab, timers) | macOS defaults, `io.github.alcatraz627.switchboard` |
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
`--probe-timers` exercises all of this on the real Keep Awake switch and reads
the power assertion back from `pmset`.

## Headless checks

Every surface can be checked without a screen:

```
Switchboard --dump                        Machine tab rows as text
Switchboard --dump-policy [--scope DIR]   Agents tab rows as text
Switchboard --snapshot out.png --tab usage [--light]
Switchboard --probe-timers                timed-flip engine (flips Keep Awake, restores it)
```

`scripts/snapshots.sh` renders every tab in both appearances.

## Talking to other apps

- `dev.switchboard.toggle` (distributed notification) opens or closes the
  panel. The claude-instances dropdown uses it.
- `dev.switchboard.usage-zones-changed` is posted when the Usage tab's warn or
  danger zone moves. The same values are written into claude-instances'
  preferences, since its icon is coloured by them.
