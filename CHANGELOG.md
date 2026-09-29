# Changelog

## Unreleased

- **Copy, don't launch**: Shell, the host menu's chat, info, logs and recipes,
  and Repos' Terminal now copy a ready command instead of opening Ghostty.
  csync commands carry `CSYNC_ACTOR=human` and csync's full path, so they work
  when pasted anywhere; opened from the panel, csync had refused them as an
  agent's.
- `scripts/build.sh` starts the build copy with a clean environment, as launchd
  does for the installed app, instead of passing on the caller's variables.

- **Faster panel**: a full refresh takes about 1.5 s instead of about 12. The
  probes run side by side, one refresh runs at a time (opening the panel used
  to start two), and the git scan answers from its last result while it
  rescans in the background.
- **Failures you can trust**: a probe that fails keeps its last reading
  instead of emptying its group; "Fix" on the csync console no longer reports
  success after a timeout; a damaged saved-devices or bulb-names file is left
  alone instead of being overwritten by the next add or rename; one malformed
  launchd plist no longer hides every scheduled job; Decision Pages, Board
  sync and snooze Lift no longer freeze the panel while they run.

- **Needs you**: a strip above the tabs, shown only while something waits:
  pushes held by the push gate and actions behind an "ask" policy, with the
  session they belong to. Copy puts the approve line on the clipboard to paste
  into that session; Cancel does what typing `cancel push` or `deny` does.
  The panel never approves by itself, because a button in an app is something
  an agent could press. Leftovers from ended sessions fold into one row with
  Clear all. The old "Push approvals" row in Guards moved here.

- **Remote**: each online host has a "…" menu: chat with its csync-assist in
  a terminal (or copy that command), Info, Logs and Recipes in a terminal,
  keep connected on or off, and copyable lines for run, push, pull, say and
  open. Screenshot says plainly when a host has no screen, and gives up after
  25 s on a machine that is asleep.
- **Dev servers**: a running server you did not start with pm2 can be
  stopped. One that launchd runs (claudebook) offers Disable, since a kill
  would only bring it back; others offer Kill. Both ask first.
- **Schedules**: Disable and Enable per job. Disabled jobs stay off across
  restarts; Enable loads a job again without running it now.
- Row names and notes wrap to a second line instead of ending in "…".

- **Remote tab** (when csync is installed): console health with Fix
  (`csync doctor --fix`), each host with Screenshot, Shell (a Ghostty window)
  and Teardown (asks first), Forget for expired invites and offline hosts, and
  Invite, which asks for a name in the row and copies the paste line.
- **Machine > Repos**: git repositories under ~/Code that need attention,
  folded into unpushed commits, uncommitted changes and worktrees to tidy,
  each with Finder, Terminal, Editor and Fetch, and Prune (asks first) where a
  worktree record is stale. Nothing commits, pushes or resets. Scanned in
  parallel and cached for two minutes.
- **Machine > Drives**: every external disk and mounted disk image with its
  format and free space, and Finder, Eject and Disk Utility. The group is
  absent when nothing is attached; the boot disk can never be ejected.
- **Controls tab**: sound output (pick a device, volume, mute), built-in
  display brightness, Wi-Fi on/off with the network name (after you allow
  Location, which macOS requires for it), and Bluetooth on/off with paired
  devices to connect or disconnect. Turning Wi-Fi or Bluetooth off asks first.
  `--probe-controls` checks the write paths headlessly.

- Every row button is an icon (play, stop, log, copy, trash, shield…), like
  the timer beside it, with its name in the tooltip. Copy turns into a green
  check for a moment.

## 0.2.0 (2026-09-29)

- **Machine > Dev servers**: the port ledger in the panel. Local services
  (running first, Start or Stop when pm2 runs them, a link when live), your
  pinned ports, and one-offs with Reap for the expired ones; Reap asks first
  and names any expired one that is still running. A link opens the port
  policy.
- **Machine > Local models**: what Ollama holds in memory, with size, time
  left and Unload; the warm companion (Load / Unload, same as `warm on/off`);
  memory pressure; a mem-guard switch; and running mlx jobs.
- Row buttons that fail say so in a sentence: "Couldn't stop Relay: …".
- **Home**: rename a bulb by clicking its name (Enter saves, Esc cancels). It
  works for a bulb that is not answering too. The old Rename… alert opened
  from inside the panel's menu and never saved a name.

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
- **Warden** also has a transcript icon: it opens the warden's current session
  in a window, rendered by the claude-instances session hub, which it starts
  when it is off.

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
