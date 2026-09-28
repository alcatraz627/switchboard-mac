# Changelog

## Unreleased

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
