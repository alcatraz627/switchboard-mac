# Changelog

## Unreleased

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
