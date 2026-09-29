# Changelog

## Unreleased

- **One time picker** for every snooze, timed flip, expiry, reminder and timer:
  preset chips, a field that reads "90m", "3h", "tomorrow 9am" or "fri 5pm",
  and a calendar.
- **Timers** tab: several labelled, coloured countdowns with a sound and a
  notification. **Queue** tab: gcc schedules, cron duties (dead ones first),
  the deploy queue and open proposals.
- Notes save as you type; the notes folder shows under the list and can be
  changed in Settings. The hover preview now appears (it never did), with
  timers, the next reminder, All clear, and a red or yellow icon dot.

- **Notes**: a compose bar (Enter saves, or save from the clipboard, or save
  and copy the path), one markdown file per note, copy path / content / title,
  tags, an expiry that dims a note into a collapsed Expired section, reminders
  in macOS Reminders once or on a repeat, and drag to reorder.
- **Settings**: show or hide any tab and any section; hidden ones are not read
  at all. Choose what the hover preview shows.
- **Hover preview**: rest the pointer on the menu bar icon for the Claude
  limits, what waits on you and problems; optional timers, services and a dot
  on the icon.
- **Claude MCP** (was Plugins & MCP): turn plugins and project MCP servers on
  and off; off ones are struck through. **Hooks** (was Rules & Hooks).
- **Approvals** moved to the last tab and the Needs-you strip is gone. An
  approved item waits in its own section and no longer counts in the badge.
- Bulbs reorder by drag. Search waits 250 ms after typing, and every text field
  takes ⌘A, ⌘X, ⌘C, ⌘V and ⌘Z.

- **Twelve tabs**, in this order: Approvals, Agents, Usage, Rules & Hooks,
  Ledger, Library, Runtime, Plugins & MCP, Machine, Controls, Home, Remote.
  The list tabs share one search, rows that open to their details, and paths
  that copy; a long section shows six rows and a Show all row.
- **Approvals**: the first tab while anything waits, with a yellow count of
  items a live session is waiting on. Pushes, policy asks, and what ended
  sessions left behind, each with Approve, Copy, Cancel and details. The
  Needs-you strip stays on the other tabs for now and shows the same count.
  Cancel from the panel tells the waiting session, as typing it does.
- **Library** (was Skills): skills, parked skills with the command that
  installs one, feature and convention docs and global memories flagged when
  past their review date, personas, and every script by its header comment.
- **Rules & Hooks**: every rule, always-loaded or scoped, with the
  always-loaded size cap flagged; every hook with the events it runs on from
  settings.json or a hook-orchestrator tasks file, hooks with no event first;
  Gates and Permission prompts moved here from Machine.
- **Ledger**: mistakes by pattern, most recurring first, with the check that
  would have caught each; open and closed proposals. Rows copy their CLI line.
- **Runtime**: Services, Dev servers, Local models and Schedules, moved from
  Machine. **Plugins & MCP**: installed plugins and MCP servers, everywhere or
  per project, read-only, with keys and tokens never shown.
- **Machine** keeps Session, Drives and Repos; Context moved to Agents.
- **Failures say why**: a command that fails, hangs or cannot start is told
  apart from one with nothing to say, and a group whose source fails says so
  instead of vanishing. launchd, pm2 and permission errors read as sentences.
  The kanban switch, hub restart and Codex ask have time limits; a timed flip
  that did not land says so; an eject says whether the drive went; Controls
  and the transcript window say what went wrong instead of doing nothing.
- Row buttons keep their size beside long text, and titles, notes and the
  footer wrap instead of ending in an ellipsis.

- **Needs you: Approve, Copy, Cancel and details on every item**, pushes and
  policy asks alike. Approve writes the same single-use file the typed approve
  line writes, then wakes the waiting session with a claude-ipc request so it
  runs at once (an inform would wait for its next turn). An approved item says
  so until its session runs it. Each row opens to its repository or action,
  session, folder, time and lines. `--probe-approve` checks both kinds in a
  scratch folder.

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
