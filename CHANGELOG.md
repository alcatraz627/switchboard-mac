# Changelog

## Unreleased

- **Machine > Guards**: every gate is listed, not only the muted ones. Gates
  opens inside the panel to the ones that are off (muted, with Re-arm; snoozed
  through hook-snooze.sh, with its date and Lift), with the rest folded under
  "N on". Permission prompts opens to a switch per prompt. The old AppKit
  drop-down menus for both are gone.
- Rows that open a list or a menu are clickable across the whole row.
- **Machine > Schedules** opens inside the panel too: every launchd job is its
  own row with Start or Stop and Open (its log, or the plist when it keeps no
  log). Stopping an always-on agent asks first, since launchd will not bring
  it back until Start. Switchboard's own agent offers Open only. Two jobs that
  share a launchd label (pm2's user and root agents) now show as two rows.
- **Machine > Wake a device** opens in place: Wake and Forget per saved
  machine, and Add… at the end.
- **ipc Broker** and **Warden** have a Copy button for the command that opens
  them in a terminal (`claude-ipc -i`, `claude-warden open`). The warden one
  opens a fork, so the running warden is never touched.

- **Machine > Context**: switch the claude.ai connectors (Vercel, Linear,
  Figma, Slack…) and the browser tools (Playwright, Chrome DevTools) off for
  new Claude sessions, so their tool names and instructions stop loading.
  Takes effect from the next new session; running ones keep what they have.

- **Home**: pick any colour for a bulb (a hue strip, eight swatches, and a way
  back to white), and set how fast an animated scene moves.
- `--snapshot --expand` renders the colour strips open, for checking.
- **Every control and reading now shows pending and failure the same way**:
  changes show at once, a spinner appears only if a save takes longer than
  350 ms, a failed change snaps back with a plain-words line and Retry, and
  readings show their age (amber when old). See docs/design-kit.md.
- **Home**: bulbs no longer vanish when a scan misses them. Discovery repeats
  its broadcast and asks every bulb seen before directly; one that still does
  not answer stays listed as not answering. Measured before: 3 of 8 scans
  found 3, 2 and 0 of 5 bulbs; after: 8 of 8 found all 5.
- **Usage**: opening the panel never starts Codex. Codex numbers come from the
  usage gate's cache with their age; "Ask Codex now" is the only path that
  asks Codex itself, and it says so when the gate is muted.

## 0.1.0 (2026-09-29)

First release as its own app. Switchboard used to run as a second icon inside
the claude-instances menu bar widget.

- **Agents**: every policy in the agent policy store with the control its type
  asks for, per-repo overrides, and a timed flip on any switch or choice.
- **Usage**: Claude and Codex usage bars with warn and danger zones, and the
  policy thresholds that act on them.
- **Machine**: muted guards, suppressed permission prompts and stale push
  approvals; services (kanban, session hub, ipc broker, decision pages,
  warden); launchd schedules with run now, plist and log; Keep Awake with the
  other processes holding the Mac awake; wake-on-LAN for saved devices.
- **Home**: WiZ bulbs found on the local network, with on/off, brightness,
  warmth, scenes and names.
- Tools from a Claude Code setup (`~/.claude`) are optional; their rows hide
  when the tool is missing.
- Settings, saved devices and bulb names carry over from claude-instances on
  first launch.
- Switchboard now finds muted guards read by cron gates and adapter scripts,
  not only those read by hooks.
- Headless checks: `--dump`, `--dump-policy`, `--snapshot`, `--probe-timers`.
