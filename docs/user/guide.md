# Switchboard user guide

This guide is for the people who use Switchboard, not the people who build it. It says what each tab shows, what every button does, which ones ask before they act, and what you will see when something is missing or broken. Where a behaviour depends on tools outside the app (a Claude Code setup in `~/.claude`, csync, pm2), the guide says so.

For what changed in each release, read [CHANGELOG.md](../../CHANGELOG.md). For how the app is built, start at the [docs index](../README.md). This guide matches version 0.4.0.

Contents: [What Switchboard is](#what-switchboard-is) · [How every tab behaves](#how-every-tab-behaves) · [The tabs](#the-tabs) · [Settings in depth](#settings-in-depth) · [Permissions and privacy](#permissions-and-privacy) · [Troubleshooting](#troubleshooting)

## What Switchboard is

Switchboard is a small macOS menu bar app that puts the switches you would otherwise hunt for in five places into one panel: keeping the Mac awake, which background jobs are failing, the lights in the room, how much of your Claude and Codex quota is left, and what your AI agents are allowed to do on your behalf. Each question gets its own tab, and any tab can be hidden. There is no server, no account and no cloud. The panel reads files and runs a few short helper scripts when you open it or flip a switch.

It needs macOS 13 or later. It has no Dock icon and no window of its own, only the menu bar icon (three vertical faders) and the panel it opens.

### Opening the panel

Click the icon to open the panel and click it again to close it. Clicking anywhere else also closes it. The panel opens on the tab you used last (Agents the first time, or the first visible tab if that one is hidden). A footer carries a hint for the tab and a reload arrow that reads the current tab again.

The tabs are grouped into five spaces along the top: Claude, Records, Desk, Mac and Around. Click a space and its tabs appear under it, each with its icon; the tab you are on is underlined. A space opens on the tab you last used in it, and a space with only one visible tab shows no second row. Settings (the gear) and Approvals (the raised hand, with its count) sit at the right of the header, beside one line about the current tab, because they are about the panel and about you rather than places among the others.

| Space | Tabs |
|---|---|
| Claude | Agents, Usage, Claude MCP, Hooks, Library |
| Records | Ledger, Queue |
| Desk | Notes, Timers |
| Mac | Machine, Runtime, Controls |
| Around | Home, Remote |

Every visible tab is refreshed when the panel opens, and a tab is refreshed again when you click it. The list tabs (Hooks, Ledger, Queue, Library and Claude MCP) are read once when the app starts and are not read again within 20 seconds of their last read, so opening the panel does not refill them every time. While the panel stays open, the Agents values and the Claude usage numbers are re-read every 30 seconds. A hidden tab is never refreshed.

If you installed with `scripts/build.sh --install`, Switchboard starts at login. Other tools can open or close the panel by posting the distributed notification `dev.switchboard.toggle`.

### The tabs at a glance

The default order is below. You can change it in Settings (see [Settings in depth](#settings-in-depth)).

| Tab | The question it answers | When it is missing |
|---|---|---|
| Agents | What may my agents do as me? | Hidden when the policy tool `~/.claude/scripts/pol/pol.sh` is not installed |
| Usage | How much of my Claude and Codex quota is left? | Always there |
| Claude MCP | What extends Claude Code: plugins and MCP servers? | Always there |
| Hooks | Which rules and hooks are live, and which guards are off? | Always there |
| Library | What skills, docs, personas and scripts exist? | Always there |
| Ledger | What keeps going wrong, and what is proposed? | Always there |
| Queue | What is lined up to happen later? | Always there |
| Notes | What did I want to keep at hand? | Always there |
| Timers | How long until the tea is ready? | Always there |
| Machine | What is this Mac doing? | Always there |
| Runtime | What is running? | Always there |
| Controls | Sound, screen, Wi-Fi, Bluetooth | Always there |
| Home | What are the lights doing? | Always there |
| Remote | What are my other machines doing? | Hidden when csync is not installed |
| Settings | What does the panel show? | Always there |
| Approvals | What is waiting on me? | Shown only while something waits |

### The hover card

Rest the pointer on the menu bar icon and a small card opens under it. It stays open while the pointer is on the icon or on the card, and closes a moment after the pointer leaves both (the delay is yours to set, see [Settings in depth](#settings-in-depth)). It does not open while the panel itself is open. The card is made of pages, and it reopens on the page you last left it on.

| Page | What it shows |
|---|---|
| Sessions | Every Claude Code session open on this Mac, first in the order. A strip says how many need you (yellow), are working (green) and are idle (grey), what they have cost so far, and how long ago the list was read. The session that has waited on you longest gets a card with Claude's last words in full. Every other session is one line, grouped Needs you, Working, Idle: click it to read its transcript, or use its three icons to bring its terminal forward, copy its folder, or copy its ipc id. Hover a line for its branch, model, context, tokens, cost, memory, last prompt and focus file. Hub, at the bottom, opens the session hub's board, where past sessions live. A session needs you once Claude finishes its turn; one left unanswered for over an hour counts as idle. The icon in the menu bar shows how many sessions are open |
| Now | Six shortcuts that open Agents, Hooks, Notes, Timers, Controls and Machine, and under them one row of badges, one for each thing that needs you. A badge opens its tab with the search filled in, so the row it names is in view. With nothing to show it says "Nothing needs you" |
| Limits | Claude 5h, Claude 7d and Codex 7d, each with its icon, its percentage and its reset time. The per-model and reserve windows stay on the Usage tab |
| Approvals | The pushes and asks waiting on you, with Approve and Cancel |
| Bulbs | The lights that are on as rows, the others as small chips you click to switch on |
| Pinned notes | The notes you pinned on the Notes tab |
| Timers, Controls, Local models | Off until you switch them on in Settings under Hover pages |

Every page has a button that opens its full tab.

To move between pages, scroll over the icon or over the card's title bar, click a pill in the title bar, or press the page's number once the card has the keyboard. Scrolling over a page's content leaves the page alone, so a long list can still scroll. The gear on Now opens the hover settings in the panel.

What Now shows under its shortcuts is your choice, made in Settings under Now page. Each item is one switch.

| Item | On by default | What it adds |
|---|---|---|
| Waiting on you | Yes | How many pushes and asks wait, and the oldest |
| Problems | Yes | Sources that failed to read, failing jobs and the like, as badges |
| Running timers | Yes | Up to two running timers, timed flips such as Keep Awake with the time left, and the next note reminder |
| Services down | No | Kanban, the session hub or the ipc broker, only when down |
| Dot on the icon | No | Not a badge. It puts a small dot on the menu bar icon itself |

### What the icon dot means

With "Dot on the icon" switched on, a yellow dot means something is waiting on you (something on the Approvals tab). A red dot means something is wrong, and red wins over yellow. The dot is off by default. Opening the panel while the dot is red or yellow lands on the tab that raised it, once for each new cause.

Every problem is either an error or a warning. Only errors turn the icon red. These are errors, judged from the last read of your Mac:

- a source could not be read (the message names the helper, for example `gitscan.py`),
- a scheduled job's last run failed,
- a timed flip could not turn its switch on or off.

These are warnings. They show in orange as badges on Now but never turn the icon red and never pull the panel to their tab:

- one or more hook gates are off,
- a hook script has no event, or its file is missing.

## How every tab behaves

Most tabs are built from the same few pieces, so what you learn on one carries to the rest.

### Rows that open

A row with a small chevron on its right opens in place to show its details. Click anywhere on the row, not just the chevron. The details appear as smaller rows underneath, and click again to fold them. In the list tabs, the last detail row is usually the file behind the entry, with a copy button.

### Copy buttons

Every button on a row is a small icon; hover it for its name. A copy button puts text on the clipboard and shows a check mark for a moment. A row whose only action is a copy (a file path) copies when you click anywhere on it. What gets copied is always plain text you could paste into a terminal or hand to an agent: a path, a command, a line to paste into a session.

### Search and Show all

The list tabs (Hooks, Ledger, Queue, Library, Claude MCP) and Runtime have a search field pinned above the list, and so does Settings. Type a few words; the list narrows once you pause for a quarter of a second. A row matches when every word appears somewhere in its name, its summary line or its opened details, in any order and in any case. Sections with no match disappear while you search. The field says only "Search" (hover it to see what it covers). The X in the field clears it. Escape lets go of the keyboard and keeps your search.

To keep long lists short, a section with more than seven rows shows its first six and a row reading "Show all 23", with the note "17 more; or search above". Click it and every row shows, ending with "Show fewer". Searching always shows every match.

The other tabs (Notes, Timers, Controls, Home, Machine, Remote, Usage, Agents, Approvals) have no search.

### Buttons that run something

A button that does real work shows a small spinner in place of its icon, and the row's other buttons wait. If it fails, the row grows one red line: "Couldn't stop Kanban: the reason", with an X to dismiss it. The reason is worded in plain language where the app knows the usual causes (launchd would not load a job, pm2 has no such process, macOS refused permission, a command is not installed) and otherwise is the first meaningful line the tool printed. Failures are also written to the log.

A few buttons ask first, with a confirmation dialog that names what will happen. This guide says which ones in each tab.

### Switches, the spinner and failure lines

A switch moves the moment you click it, so it never feels stuck. If saving takes longer than about a third of a second, a small spinner replaces the row's status icon until the change is confirmed, and the switch ignores further clicks meanwhile.

If a change does not stick, the switch snaps back to the real value and the row grows a red line saying what went wrong, with Retry and an X. For a plain on/off switch that reports nothing back, Switchboard waits 8 seconds and then judges by the next fresh reading of your Mac, however long that takes. A slow helper therefore makes the confirmation late, never wrong. The line stays until you dismiss it or a later change to that row succeeds.

### Readings, their age, and what missing looks like

Every value that comes from outside the app carries its age: "as of 3m ago". The age is grey until the reading is more than an hour old (ten minutes on the Home tab), then amber.

| What you see | What it means |
|---|---|
| "Reading…" | The first value has not arrived yet |
| "as of 3m ago" in grey | A fresh reading |
| An amber "as of 3m ago · couldn't refresh: the reason" | The last refresh failed; the old values stay on screen |
| A red line, with Retry | There is no value at all, because reading failed |
| A grey line with a small minus sign, nothing to click | The source is not installed or is deliberately muted. This is not a failure |
| Grey "Nothing here yet." in a list section | The source was read and is empty |

### Timed flips, "for a while"

Most plain on/off switches (Keep Awake and Board sync on Machine, the service switches on Runtime, and the two Context switches on Agents) can be flipped for a while: "Keep Awake for 2 hours", "Kanban off until 6 PM". These rows have a small timer icon beside the switch. Click it and pick when the switch should go back.

The label says which way it goes: on a switch that is on it reads "Off until…", on one that is off it reads "On until…". Picking a time flips the switch now and saves the time it should come back. While a timer runs, the row shows "→ On in 1h 20m" in place of its note, with an X that cancels the timer and keeps the current state. Clicking the icon again offers "Change when it turns back on" plus two links, "End now" (flip it back at once) and "Cancel the timer". Re-timing a running flip keeps the original state it will return to.

The timer is saved, so it survives a restart, and Switchboard checks for due timers every 15 seconds. If the app was closed when the time passed, the switch flips back on the first check after it starts. When the time comes, the switch is read first and flipped only if it is not already where it should be, so a change you made by hand in between is never undone. A few seconds later (10) it is read again, and if it still is not right the row shows "the timer could not turn it on; it is still off" until you flip it or time it again. A timer on a switch whose section you have hidden in Settings still fires.

Switches that cannot take a timer show no icon: read-only rows, the ipc Broker, the mem-guard switch, the permission-prompt switches, and plugin toggles.

Agents policy rows have their own version: a clock icon that says "Switch later, keeping Allow until then". It is described under [Agents](#agents).

#### The time picker

Every place that asks for a time (a timed flip, a note's expiry or reminder, a timer, an Agents "switch later") opens the same small picker.

- A grid of preset chips. Hover a chip to see the exact time it means.
- A field, focused as soon as the picker opens: type a time and press Return.
- A calendar button that opens a date grid and a time field with a Set button. Dates start from today.
- Sometimes a choice row above the chips (for example "Once / Every day / Every week / Every month" on a reminder) and links below (for example "No expiry" or "End now").

The presets depend on what is being set.

| Used for | Presets |
|---|---|
| Switches and Agents snoozes | 30 min, 1 h, 2 h, 4 h, End of day (23:59), Tmrw 9 AM, 3 days, 1 week |
| Note expiry and reminders | 1 h, 3 h, Tonight 8 PM, Tmrw 9 AM, 3 days, 1 week, 1 month |
| Timers | 1, 5, 10, 15, 25, 30, 45 and 60 min |

The typed field reads these forms, and all of them work in every picker:

| Type | Means |
|---|---|
| `90m`, `3h`, `2d` | That long from now. A decimal such as `1.5h` works |
| `in 3h` | The same, with an optional "in" |
| `1h30m`, `1d 2h`, `5 min`, `2 hours`, `1 hr 15 min` | Parts add up, and units can be spelled out |
| `tomorrow 9am`, `fri 5pm`, `2 Oct 14:00` | Any date or time phrase macOS itself recognises |
| `9am` | The next 9 AM. If it has passed today, it means tomorrow, unless you typed "today" |

While you type, a line under the field previews the result ("Thu 2 Oct, 5:00 PM · in 3h 20m"). If it cannot read what you typed, it says "Not a time I can read yet", and Return does nothing. Zero or negative durations are not accepted.

## The tabs

### Agents

Answers: what may my agents do as me?

Agents lists the policies in your agent policy store: rows such as whether agents may act on GitHub, Slack or Linear, commit, push, deploy, or use particular model seats. Which rows appear, and how they are grouped, comes from the policy registry, so the list is whatever your registry defines. The footer says "Applies to every session at once. Only you can change it."

At the top, "Applies to" opens a scope list: Everywhere, or one repository. The list holds every repository that has its own override and every repository where a Claude session is running right now (each has a small button that opens its folder in Finder). In a repository scope you only see the policies that can be overridden per repository, with the line "Overrides for ~/Code/x. A row with no override follows the Everywhere value."

Each row shows its label and one control chosen by the kind of policy: an Allowed/Blocked switch (the word "Blocked" turns red), a segmented choice for three options or fewer, a menu for more, or a slider with its value. An orange dot after the label means the value differs from the default; hover it to see the default. Under the label you may see:

- "Default is Allow" with an undo arrow, when you set the value yourself. The arrow removes your value.
- In a repository scope, "Follows Everywhere", or "Everywhere is Block" with an undo arrow that removes this repository's override.
- A pending timed change, described next.

The clock icon on a row is "Switch later, keeping Allow until then". Pick the value to switch to (for example "To Block"), then a time. The row then reads "→ Block in 2h 10m" with an X that cancels the timed change and keeps the current value. These timed changes are kept by the policy store itself, not by Switchboard's own timer engine. The shortest one is one minute.

Changes take effect immediately and do not ask first. They go through the policy tool, run as you (Switchboard removes the markers that make the tool treat a caller as an agent, because this panel is your own surface). If the tool refuses, the row grows the tool's message in red with Retry. If the whole store cannot be read, the top of the tab says so, with Retry, and shows the old values as stale if there are any.

One section can be hidden, "Context". It holds two switches that shrink what every new Claude session loads at start:

| Switch | What it does |
|---|---|
| claude.ai connectors | Off keeps the connectors' tool names and instructions (Vercel, Linear, Figma, Slack and the like) out of new sessions. It sets `disableClaudeAiConnectors` in `~/.claude/settings.json` |
| Browser tools | Turns the Playwright and Chrome DevTools plugins off or on. Off also hides their skills. It appears only when one of those plugins is installed |

Both apply from the next new session, since a running session keeps what it started with. Context appears under Everywhere only, never in a repository scope. Both can take a timer. Every write to `settings.json` is read back to confirm, and keeps a timestamped backup next to it (the five newest are kept).

Data comes from the policy tool and from `~/.claude/settings.json`. The percentage limits in the policy registry are shown on the Usage tab instead, next to the bars they act on. Nothing on this tab needs a macOS permission.

### Usage

Answers: how much of my Claude and Codex quota is left?

Two sections, Claude and Codex, each with a status line, a link to the provider's usage page, and a card of bars. A bar shows the window's name, the percentage used, and "resets in 2h 10m" when the reset time is known. Small tick marks on the bar show the thresholds that act on it. The bar is green, orange at the warn line and red at the danger line.

Claude. The numbers come from what Claude Code hands its statusline (`~/.claude/widgets/.rate-limits-raw.json`, with `.limits.json` as a fallback). Every window it sends appears: "5 hours", "Week", and any per-model window such as "Week · Opus". The ticks are warn, danger and, on the 5-hour and weekly bars, "stand-down", the usage level at which the session warden stands down (from your policy, 90 if none). Two sliders set "Warn at" and "Danger at" between 50 and 100 percent in steps of five. The defaults are 70 and 90. Until Claude Code writes a reading you see "No usage reading yet. It arrives with the next statusline render."

Codex. The numbers come from a cache kept by the Codex usage gate (`~/.claude/adapters/codex/state/limits.json`). Opening the panel never starts Codex. To get fresh numbers, click "Ask Codex now": it starts a short-lived Codex process, shows a spinner, and gives up after 60 seconds. If it fails, the reason shows under the header (up to 140 characters), and older numbers stay on screen in amber. If the gate is muted (a `.no-codex-usage-gate` file in `~/.claude`), it refuses and says so. The single slider "Warn at" (default 60) sets where a bar turns orange, and the red line is the policy's Codex seat stand-down (75 if none), marked "seat stand-down". If Codex has free full resets available, a line says how many and when the first expires. Without the Codex adapter the section reads "Codex usage needs the Codex adapter in ~/.claude."

Below the two sections, a group called "What acts on these numbers" shows the policy sliders from the registry that end in a percentage (moved here from Agents). It appears only when the policy store has any.

Hiding: the Claude and Codex sections can each be hidden. No macOS permission is needed. The Usage page links open in your browser only when clicked.

### Claude MCP

Answers: what extends Claude Code, and can I turn it off for new sessions?

The tab's id is `plugins`; the footer says "On and off apply to new sessions. MCP keys and tokens are never shown." A search field and an All / Everywhere / One project selector sit above the list. The selector hides or shows the sections whose names start with "Project".

Four sections:

| Section | What it lists | Source |
|---|---|---|
| Plugins | Installed Claude Code plugins that apply everywhere | `~/.claude/plugins/installed_plugins.json`, with on/off from `enabledPlugins` in `settings.json` |
| MCP servers | Servers set up in your own Claude config, everywhere or for one project as its tag says | `~/.claude.json` |
| Project plugins | Plugins installed for one project | Same file as Plugins |
| Project MCP servers | Every `.mcp.json` found in a repository under `~/Code`, at most four folders deep | The `.mcp.json` files, plus each project's Claude settings |

A plugin row shows the name, a tag ("on · marketplace", or "off · marketplace · project name"), and the first sentence of its description. Opened, it shows what it is, what it adds (counts of skills, commands, agents and hooks, or "an MCP server"), its source and version, the project if any, and its state. The last row copies the path to its `plugin.json`. Plugins that are on come first, off ones are struck through and dimmed.

Disable or Enable on a plugin writes its entry in `enabledPlugins` in `~/.claude/settings.json`. It does not ask first, it applies to new sessions only, the write is read back to confirm, and a timestamped backup is kept beside the file. If `settings.json` is missing or is not valid JSON, Switchboard refuses to write ("~/.claude/settings.json could not be written") rather than invent a config.

An MCP server row shows how it runs (the command and its arguments, or "http to host"), the names of its environment variables with "(values not shown)", the project if any, and the file it is configured in. Servers in your own Claude config have no button: Claude Code offers no everywhere-off switch for them, and the opened row says so and points to `/mcp` inside a session, or `claude mcp remove <name>` to remove one.

A project MCP server (from a `.mcp.json`) has a tag that reads "on", "off" or "asks first". "Asks first" means it is not yet approved and Claude Code will ask the first time a session starts in that project. Its Disable or Enable button writes `enabledMcpjsonServers` and `disabledMcpjsonServers` in that project's `.claude/settings.local.json`, the per-user file Claude Code keeps out of commits. It creates the file with just those keys if it is not there, leaves a file that is not valid JSON alone and says so, and reads the result back. A disable anywhere wins over an enable. It does not ask first.

Keys and tokens never reach the panel. Environment variables show names only. A URL shows only its host. Arguments are checked and hidden when they look like a credential: a `key=value` pair whose name mentions key, token, secret, password or auth becomes `name=•••`; a password inside a connection URL (`user:password@`) becomes `•••@`; and any long unbroken token (28 or more letters, digits, dashes, dots or underscores, with no slash) becomes `•••`. The hiding follows those patterns, so a short secret passed as its own argument would not match.

If `installed_plugins.json` or `~/.claude.json` cannot be read, the section shows a red line naming the file. Nothing needs a macOS permission.

### Hooks

Answers: which behavioural rules and hook scripts are live, and are any guards switched off?

The tab's id is `rules`. It has three sections: Guards, Rules and Hook scripts. The footer reads "Problems sort first: a hook with no event, or one whose file is gone."

Guards holds two rows.

The Gates row counts every hook gate on this machine and opens to them. Its badge is "ok" when all are on, and a yellow count of the ones that are off. Inside, the gates that are off come first, then a single row "N on" that folds all the armed ones. A gate can be off in two ways.

| State | What it shows | Button |
|---|---|---|
| Muted | "muted since 12 Sep": a file in `~/.claude` (named for the gate, such as `.no-review-required`) switches the hook off | Re-arm deletes that file so the hook fires again. It does not ask first |
| Snoozed | "snoozed until 30 Sep", plus the scope if it is not global. The reason shows on hover | Lift ends the snooze through the hook tool's own command. It does not ask first |

The list of gates is found by reading the hook scripts themselves for the mute files they look for, so it grows as hooks are added. Muting stays a deliberate act in a shell: Switchboard only ever puts a protection back. A file that records a standing policy lift (`.allow-fable-subagents`) is left out, since listing it would nag you to undo a decision. This row needs the hooks folder `~/.claude/scripts/hooks`.

The Permission prompts row opens to three of Claude Code's confirmation prompts: "Dangerous-mode prompt", "Auto-permission prompt" and "Workflow usage warning". Each is a switch where on means the prompt is active ("asks first") and off means it is suppressed. The row's badge is "ok", or a yellow count of suppressed ones. Turning a prompt off is the one thing in Switchboard that weakens a safeguard, so it asks first: "Suppress the dangerous-mode prompt?", "This removes a confirmation step for every session on this machine, not just this one", with Suppress and Cancel. Turning a prompt back on does not ask. The switches write to `~/.claude/settings.json`, with the same read-back and backup as above. The row needs that file.

Rules lists every markdown file in `~/.claude/rules` except its README and index. Each row shows a tag ("always" for rules every session loads, "scoped" for rules that load only when a matching file is touched) and the first sentence of the rule's brief. Opened, it shows what it says, when it loads, what else triggers it, related rules, and its size in bytes. An always-loaded rule over 2,200 bytes is flagged as over the cap. The last row copies the file's path.

Hook scripts lists every script in `~/.claude/scripts/hooks` plus any script that a hook names. The tag says where it runs: the events it is wired to in `settings.json` or `settings.local.json`, or in a hook-orchestrator tasks file ("PreToolUse (orchestrator)"), or "muted in" an event when its line in a tasks file is commented out with `# DISABLED`, or "run by another-hook.sh" when another script calls it, or "not wired" or "missing file". The last two are the problems, and they sort first. Opened, a script shows the header comment that says what it does, what it runs on, and who calls it, with a copyable path.

When `~/.claude/rules` or the hooks folder cannot be read, the section shows a red line naming it. The Guards rows are simply absent if the tools they need are not installed.

### Library

Answers: what skills, docs, personas and scripts do I have?

Five sections, all read from `~/.claude`. The footer says "Open a row for its details; the path copies on click."

| Section | What each row is | Notes |
|---|---|---|
| Skills | A skill in `~/.claude/skills`, named `/name`, with the first sentence of its description | Opens to the full description and a copyable path |
| Parked skills | A skill kept in `~/.claude/skills-parked` but not loaded, tagged "parked" | Opens to when to bring it back and its tags (from the folder's `INDEX.md`), its description, and the command that installs it into a project. The Copy button copies that command |
| Knowledge | Feature docs, convention docs and global memories, tagged by kind | A doc past its own review date is tagged "past review by 12 days". Opens to what it is, when it loads, related docs, and its last update |
| Personas | Working-mode personas, including those in `_proposed` (tagged "proposed") | Opens to role, domain and kind, and the command to adopt one (`/persona name`) |
| Scripts | Every `.sh` and `.py` under `~/.claude/scripts` except hooks, tests and fixtures | Summarised by the script's own header comment. Old-path symlinks are skipped so each script shows once |

If a folder is missing, its section shows a red line such as "~/.claude/skills could not be read". Nothing here changes anything except the clipboard.

### Ledger

Answers: what keeps going wrong, and what improvements are proposed?

Four sections. The footer says "Mistakes sort by how often they recur; each row copies its CLI line."

Mistakes reads `~/.claude/atone/events.jsonl` and groups events by pattern. Each row shows the pattern name, the title of the latest event, a count badge (red if the worst was severity S3, orange for S2, grey otherwise), and a tag like "S3 · last 2026-09-01". Opened, it shows the check to make before acting, what never to do again, how many times it happened (with the severity counts), and the three latest events. The last row copies the path to the write-up file when one exists. The Copy button copies `bash ~/.claude/scripts/atone.sh list --slug <pattern>`. Most frequent first, then most recent.

Open proposals and Closed proposals read `~/.claude/proposals.jsonl`, newest first. A row shows the title, the first sentence of its body, and a tag ("open · 2026-09-20 · small"). Opened, it shows the full proposal, why it was closed, its kind, tags, links, the last three updates, and when it was filed. The Copy button copies `bash ~/.claude/scripts/propose.sh show <id>`.

Checkpoints lists the last twenty checkpoints your sessions wrote with `/core-dump`, newest first, read from `~/.claude/checkpoints/index.jsonl`. A file written again shows once, at its newest. Automatic session-end and pre-compaction snapshots are left out, since they carry no summary to resume from. A row shows the checkpoint's name and a tag such as "switchboard-mac · 2 Oct, 9:14 AM". Opened, it shows where the work stopped, the project, and the line that resumes it. The Copy button copies `/catchup at <path>`. A checkpoint whose file has been deleted says "file gone" and offers nothing to copy.

A file that cannot be read shows a red line naming it. A line in a file that does not parse is skipped.

### Queue

Answers: what is lined up to happen later?

Four sections. The footer says "A cron duty whose session has ended cannot fire; those sort first."

| Section | What it lists | Source |
|---|---|---|
| Scheduled | One-shot and recurring scheduled jobs, tagged "recurring" or "at" a time | `~/.claude/scheduled/registry.json`. Opens to when, what it is about, the command and the launchd label. Copy copies `bash ~/.claude/scripts/schedule/schedule.sh list` |
| Cron duties | Duties armed by Claude sessions | `~/.claude/cron-duties/*.json`. A duty whose session has ended cannot fire; it is struck through, tagged "session ended", and sorts first. One tied to no session is treated as live |
| Deploy queue | Deploys running, then pending (up to 50 of each), then the last five done | `~/.claude/deployq`. Missing folder reads "~/.claude/deployq is not there" |
| Open proposals | The same open proposals as the Ledger | `~/.claude/proposals.jsonl` |

Everything here is read-only apart from the copy buttons.

### Notes

Answers: what did I want to keep at hand?

A compose bar is pinned above the list. A note has a title over a body. Either can be left empty, but not both. Press Enter in the title and the rest of the line moves to the top of the body, with the cursor there. Save with the check mark or with Command and Return. The other icons beside the field open the larger title-and-body editor, save what is on the clipboard as a note, and save and copy the note's path. You can pick one of eight tag colours as you write. A short message confirms ("Saved", "Saved from the clipboard", "Saved; path copied"). Saving the same text twice does not make a second note ("Already saved"). Opening the tab puts the cursor in the compose bar, unless you are editing a note below. Notes are not searchable.

Each note is one markdown file, so its path can be handed to an agent. The default folder is `~/Library/Application Support/Switchboard/notes`, and you can choose another in Settings. The file has a small header (title, created time, tags, expiry, reminder) and then the body. If you drop your own markdown file into the folder, Switchboard reads it: a file with no header takes its first line as the title (a leading `#` is dropped). Editing such a file keeps its body.

A row shows the title and a second line with the first line of the body, a dot in the note's tag colour, "reminds 3 Oct, 9:00 AM, weekly" and "expires 5 Oct, 6:00 PM". Point at a row and its buttons appear. The copy buttons follow what the note has: one copies the file's full path, one the text if there is a body, one the title if there is a title. The pin button puts the note on the Pinned notes page of the hover card. Drag the grip at the left to reorder; the order is saved. Click the row to open its editor.

The editor has the title, the body, the tag colour (shown as colour only), an expiry chip and a reminder chip. The expiry chip opens the time picker, with a "No expiry" link. Once a note has expired it dims, is struck through, and moves to a folded section at the end called "EXPIRED 2". Nothing is deleted. The reminder chip opens the picker with "Once / Every day / Every week / Every month" and a "No reminder" link. For a one-off reminder, a checkbox "Expire the note when it fires" appears. The editor saves by itself 0.7 seconds after you stop typing, and saves when you fold the row, so there is no Save button. The trash icon asks first ("The file and any reminder it set are removed").

Reminders. A reminder is created in the macOS Reminders app, in your default list, with an alarm at the time you chose and, for a repeat, a daily, weekly or monthly rule. Its notes carry the note's body and file path. It follows a change to the time, the repeat or the title, but typing in the body does not touch Reminders. Clearing the reminder or deleting the note removes that one reminder, and Switchboard touches no other reminder. The first time you set a reminder, macOS asks for Reminders access. The note is saved at once and the reminder is created when you allow it, from the note as it is then. If access is denied, a red line at the top says "Switchboard may not add reminders. Allow it in System Settings > Privacy & Security > Reminders." If you answer no to the dialog, it says "Reminders access was not given, so the reminder was not set." If Reminders itself refuses, the line says why.

If a note cannot be saved or deleted, a red line at the top says so. The folder link under the list opens the folder in Finder, and the copy icon beside it copies its path.

### Timers

Answers: how long until the tea is ready?

The top of the tab is a small form: a label field ("Label, e.g. Tea"), a row of eight colour dots, and a Start button. Press Enter in the label, or click Start, and pick how long; the timer starts at once. With no label, it is named "Timer". The picker takes minute presets and any typed time (see [the time picker](#the-time-picker)).

Each timer is a coloured row with its label, the time left as a clock ("4:05", or "1:02:05" past an hour) and a progress bar. Click the label to rename it; Enter or clicking away saves. Drag the grip to reorder. The plus button adds a minute to a running timer, or restarts a finished one for a minute. The X cancels a running timer or clears a finished one. A finished timer stays listed as "done" with "went off 3m ago" until you clear it.

When a timer goes off, Switchboard plays the Glass sound and sends a macOS notification with the timer's name and "Timer done". The sound repeats every two seconds for up to 30 seconds, and stops the moment you open the panel. Timers are saved, so a restart does not lose them. If the app was closed when a timer came due, it goes off when the app next starts.

The first time a timer starts, macOS asks whether Switchboard may send notifications. If notifications are off for Switchboard (denied, or alerts set to none), the tab shows a red line: "macOS has Switchboard's notifications off, so a timer rings here with no banner", with an Open Settings button that opens the notification settings for the app. The chime still plays. The check runs again each time you open the panel.

Timers use only the app's own storage and macOS notifications. Apple's Clock app has no way to hand timers to other apps, so these are separate from it.

### Machine

Answers: what is this Mac doing, and what needs attention on it?

Three sections, drawn in this order: Repos, Drives and Session. Each is read by its own helper script, each read has its own time limit, and a section you hide is not read at all. If a helper fails, the section keeps its last values with an amber "couldn't refresh" line; if it never worked, the line is red.

Session holds the switches and the wake list.

| Row | What it does |
|---|---|
| Keep Awake | Holds a macOS power assertion so the system does not sleep when idle, while the display still sleeps and locks. It is saved, so it comes back after a restart. The note says "sleep blocked", "system may sleep", or "also held awake by node, claude", listing other programs that hold the Mac awake. Can take a timer |
| Board sync | Whether session hooks copy the todo list to the kanban board ("todos to kanban" or "hooks skip"). Shown only when the sync tool is installed. Can take a timer |
| Wake a device | Opens to your saved devices. Each has Wake, which sends a wake-on-LAN packet (a sleeping machine takes a few seconds; there is no reply, so "sent" is all it can report), and Forget, which removes it. Neither asks. "Add a device" opens a dialog for a name and a MAC address, with Save and Cancel; if it cannot save, an alert says why. The machine must have wake-on-LAN turned on |

Saved devices live in `wol-targets.json` in `~/Library/Application Support/Switchboard`.

Drives lists external disks, SD cards and mounted disk images, one row each, with its kind, format and free space ("external · exFAT · 210.4 of 500.0 GB free"). A read-only volume, such as an installer image, shows its size and "read-only" instead. The buttons are Finder (open it), Eject and Disk Utility (opens the app, for formatting and repair; Switchboard never formats). Eject ejects the whole disk with every volume on it and does not ask first. The section is absent when nothing is attached.

Repos scans your git repositories under `~/Code`, three folders deep, and folds them by what needs doing: "Unpushed commits" (yellow), "Uncommitted changes", and "Worktrees to tidy" (detached checkouts and worktree records whose folders are gone). Each opens to its repositories, and each repository row shows its branch (or "detached") with "2 unpushed", "1 behind", "3 changed", "1 stashed" or "1 prunable worktree". A last row counts the clean ones and says when the scan ran ("12 clean · ~/Code, 3 levels deep · scanned 5m ago"). The scan is cached and answers at once, then refreshes in the background when it is over two minutes old.

| Repository button | What it does |
|---|---|
| Finder | Opens the folder |
| Terminal | Copies a `cd` command to that folder |
| Editor | Opens it in Zed, Visual Studio Code or Cursor, whichever is installed first. Absent if none is |
| Fetch | Runs `git fetch`, which looks at the remote without changing your files. Does not ask |
| Prune | Runs `git worktree prune`. Asks first, and says it removes only records whose folders no longer exist. Shown only when there is something to prune |

Switchboard never commits, pushes or resets. Hidden sections are described in [Settings in depth](#settings-in-depth). Nothing here needs a macOS permission.

### Runtime

Answers: what is running, and can I stop it?

Five sections, with a search field pinned above them . The footer says "Stop and Disable ask first; a command copies instead of opening a terminal."

**Databases** lists the services Homebrew runs through launchd (the `homebrew.mxcl.*` agents in `~/Library/LaunchAgents`), such as mongod, redis, postgres and nginx, including ones `brew services` leaves out. A row shows its ports and pid, or "stopped". Start needs no confirmation; Stop and Restart ask first, since connected apps lose their connection. Stop unloads the service so launchd does not start it straight back, and it returns at the next login. Copy puts the connection string (`redis://127.0.0.1:6379`) on the clipboard, and Open shows its log. Opened, the row lists its ports, data folder, log and launchd label, each with a copy button. A button only reports success once the service has really started or exited.

**Services** (each row appears only when its tool is installed; every switch here can take a timer, except the ipc Broker):

| Row | What it does |
|---|---|
| Kanban Board | A switch that starts or stops the kanban server (a pm2 process on port 5106). It stays off after a reboot, and this switch is where it comes back. When it is up, a link opens it in the browser. If starting fails, the row says "couldn't switch: the reason". Needs the kanban server file, pm2 and bun |
| Session Hub | The phone-facing session hub (port 5400), which lives in this repo's `hub/` folder and runs under pm2. The note says "serving :5400", or "up, address unreachable" when it is running but its phone address no longer answers, or "not running". Clicking restarts it, or stops it when it is up. Restart it after Tailscale reconnects. Its "Start at login" switch, like the ones under Kanban Board and Decision Pages, says whether it comes back after the Mac restarts, read from pm2's saved list |
| ipc Broker | Whether the cross-session message broker is up. Read-only, since it runs under launchd. Copy copies `claude-ipc -i` |
| Decision Pages | A switch for the pm2 process `decision-pages` (port 5197) |
| Warden | The session warden. The switch is your pause: "beats live", "paused by you, deltas held", or the yellow "standing down, usage >90% (auto-resumes)", which is the usage gate and clears by itself. Transcript opens a window with the warden's session (rendered by the session hub, which it starts if it is off). Copy copies `claude-warden open` |

**Dev servers** reads the port ledger, pm2 and the ports that are actually listening. Rows fold into "Local services" (persistent local services, with "3 of 5 running"), "Pinned ports" (your own ports, which agents never take), "One-offs" (demos with a time limit, "2 running · 1 expired") and a "Port policy" row that opens the port-policy document. Opened, each server shows its port and how it runs ("pm2", "running", "running outside pm2", "pm2, stopped" or "not running"), with a link to it when it is up and its own buttons:

| Button | What it does | Asks first |
|---|---|---|
| Stop, Start | `pm2 stop` or `pm2 start` for that server | No |
| Disable | For a server launchd keeps alive: stops it and keeps it off, since killing it would just restart it. Enable it again under Schedules | Yes |
| Kill | Stops whatever listens on that port. Nothing restarts it | Yes |
| Reap (on One-offs) | Stops the expired one-offs and frees their ports. Each can be brought back with `ports.sh revive` | Yes, and it names any expired one that is still running |

**Local models** appears only when the `lm` suite of local models is installed. "Ollama" shows how many models are loaded and how much memory they hold, and opens to each with an Unload button (frees its memory now, does not ask) and a "Warm companion" row whose Load or Unload button keeps the small default model loaded. "Memory pressure" shows normal, warn or critical. "mem-guard" is a switch for the watchdog that stops the largest model before macOS runs short of memory (it runs up to two hours per start). "mlx jobs" appears while image or vision jobs run outside Ollama.

**Schedules** lists your launchd agents from `~/Library/LaunchAgents` (never Apple's or installers'). "Always-on agents" folds the ones launchd keeps alive, with a green count running or a red count stopped. "Scheduled jobs" folds the ones on a clock whose last run was fine. A job whose last run failed gets its own row, red, with its exit code. A row reads like "Nightly backup · 02:00 · last run ok".

| Button | What it does | Asks first |
|---|---|---|
| Start | Runs the job now, loading it into launchd first if needed | No |
| Stop | Stops the run. For an always-on agent, unloads it so launchd stops restarting it | Only for an always-on agent |
| Disable | Stops it and keeps it off, even after a restart, until you press Enable | Yes |
| Enable | Lets it run again | No |
| Open | Opens its log, or shows its plist in Finder if it keeps no log | No |

Switchboard's own agent shows only Open, marked "this app", because Stop would quit the panel mid-click and Start would launch a second copy.

Each section reads its own source: the port ledger tool, pm2, the local-models suite and launchd. If a source fails, the section keeps its last values with an amber note, and a pm2 that does not answer says "so pm2 states are unknown". No macOS permission is needed. Some helpers use your login shell, so pm2 and similar tools are found the way they are in Terminal.

### Controls

Answers: how do I change sound, screen brightness, Wi-Fi and Bluetooth without hunting for four menu bar icons?

Four sections, each talking to macOS directly with nothing to install.

Sound shows the current output and its volume, with a mute button (when the output reports muting), a menu of outputs to switch to, and a volume slider. An output whose volume apps cannot set, such as some HDMI displays and docks, shows "volume set on the device" and no slider. If a change fails, the red line says why ("This output does not take a volume from apps.").

Display shows the built-in screen's brightness with a slider that follows your finger, never below 2 percent. It appears only when the built-in display can be read, so it is absent with the lid closed or on a Mac with no built-in screen. External displays are not controlled.

Wi-Fi shows a switch and the network name. Turning it off asks first: "Turn Wi-Fi off? Everything on this Mac that uses the network loses it, including remote sessions." Turning it on does not ask. The switch reads the result back after a moment and reports "Wi-Fi is still on" if it did not take.

Bluetooth shows a switch and, when it is on, the list of paired devices, connected ones first. Each has a connect or disconnect button with a spinner while it works; a failure says "X did not connect. Is it on and nearby?". Turning Bluetooth off asks first: "A Bluetooth keyboard, mouse or headphones disconnect at once." Turning it on does not.

Permissions on this tab:

- Wi-Fi name. macOS shows a network name only to apps with Location access. Until you allow it, the caption reads "connected · name hidden by macOS" with a "Show name" link that asks. The name is used for nothing else.
- Bluetooth. The paired-device list needs Bluetooth access, and macOS asks the first time it is read. That read happens when the panel opens or when you open this tab, whenever the Bluetooth section is shown. Hide the section in Settings and the list is never read.

### Home

Answers: what are the lights doing?

Home controls Philips WiZ smart bulbs on your home network. It talks to them directly over the local network, with no account or cloud. The panel scans for bulbs every time it opens (one broadcast, about three seconds of listening), keeps the last list on screen meanwhile, and has a reload arrow to look again.

The header has "All off" and "All on", shown when at least one bulb answers, and they act on the bulbs that are reachable. A status line says when the scan ran; it turns amber after ten minutes. If a scan fails and there are bulbs from before, they stay with an amber "couldn't refresh"; with none, a red line says "Could not look for bulbs". With none found, the card says "No bulbs answered on this network."

Each bulb row shows a lamp icon (yellow when on), its name, and a second line: "80% · Warm White", "80% · #FF9500" or "80% · 2700K" while on, "off", or "not answering" when it cannot be reached (the row then dims and its controls are disabled). Click the name to rename it; Enter saves, Escape cancels. Names live on this Mac in `wiz-names.json` in the state folder, keyed by the bulb's address, so an unreachable bulb can still be renamed. The controls are:

| Control | What it does |
|---|---|
| Switch | Turns the bulb on or off |
| Two sliders (while on) | Brightness from 10 to 100 percent, and warmth from 2200 K (warm) to 6500 K (cool) |
| Palette button (while on) | Opens a colour strip: drag a hue, click one of eight swatches, or press White to go back to white |
| Menu (ellipsis) | A list of 22 scenes (Warm White, Daylight, Focus, Relax, Sunset, Party and so on), a Slow, Normal or Fast speed for animated scenes, and Rename |
| Grip | Drag to put the bulbs in your order; it is saved |

A change shows at once. If the bulb does not answer, the row goes back and says "The bulb did not answer. It may be switched off at the wall or out of Wi-Fi range.", with Retry. None of these ask first.

### Remote

Answers: what are my other machines doing?

Remote drives other Macs through csync, a separate tool. The tab is hidden unless csync is installed (in `~/Code/Claude/csync/bin/csync` or `~/.local/bin/csync`). Every action is a csync command run as you, and csync records it in its own log. The footer says so.

Console shows one row, "Console health", the result of `csync doctor`: "relay, Tailscale and Funnel all good", or a red count with the names of failing checks. It opens to each check with its detail, failing ones first. When something fails, a Fix button runs `csync doctor --fix`. It does not ask.

Hosts lists each machine with a row like "macOS · online", "invited, waiting for the paste · expires in 40m", "invite expired", or "macOS · offline, last seen 2d ago". An online host has four buttons:

| Button | What it does | Asks first |
|---|---|---|
| Screenshot | Takes a screenshot of that machine and opens it | No |
| Shell | Copies the command that opens a shell on it, to paste in your terminal | No |
| More (menu) | Copy the chat command for csync-assist; copy `info`, `logs` or `recipes`; keep the host connected across reboots or stop doing so; copy commands to run a command, send a file, fetch a file, show a message or open an app on it | No. The copy items only fill the clipboard |
| Teardown | Ends the session and removes csync from that machine. Reconnecting needs a new invite | Yes |

A machine that is not online has Forget instead, which drops it from the list. It asks first only for a pending invite ("Cancel the invite for studio-mac?"). The last row, "Invite a machine", has an Invite button that asks for a name in the row itself, then puts the one line to paste on the other machine onto your clipboard. The copied commands begin with `CSYNC_ACTOR=human`, because csync refuses writes it takes to be an agent's.

If csync cannot be read, Console shows a red line, or an amber one with old values if there are any.

### Settings

Answers: what does the panel show?

Settings has five groups: Tabs (show or hide each tab and its sections, and put the tabs in your order), Hover pages (which pages the hover card moves through, and in what order), Mouse-away delay, Now page (what the Now page shows as badges) and Notes folder. A search field at the top narrows all of them. Every part of it is explained in [Settings in depth](#settings-in-depth). The footer says "Hidden tabs and sections are not read, so they cost nothing."

Settings cannot be hidden, and neither can Approvals.

### Approvals

Answers: what is waiting on me?

The raised-hand button in the header appears only while something waits, and carries a yellow count of items a live Claude session is waiting on you for. An item you have approved no longer counts, and neither does one whose session has ended. When the last item clears, the tab disappears and the panel moves to another tab if it was showing.

Items come from files that Claude Code's gates leave in `~/.claude`: a held push (a `.push-nonce-<session>` file) and a policy ask, an action behind an "ask" policy (a file in `~/.claude/.policy-ask`). Four sections may appear.

| Section | What is in it |
|---|---|
| Pushes | Pushes to a protected branch held by the push gate, from sessions that are still running |
| Policy asks | Actions behind an "ask" policy, held for you, from running sessions |
| Approved, waiting to run | Items you approved that the session has not yet used. The note says when, and that "the session was asked to run it; if it is idle, it runs on your next message to it" |
| Left by ended sessions | Items whose session is gone, plus approvals typed and never used. Nothing can run these |

A row shows the item ("Push switchboard-mac", "Posting to Slack"), which session it belongs to ("session in switchboard-mac") and how long ago it was held. Opened, it shows the repository or action, why it is held, the session, the session folder, when it was held, and the exact approve line and cancel line.

| Button | What it does |
|---|---|
| Approve | Writes the single-use approval file the gate reads, the same one typing the approve line writes, then sends the waiting session a message over claude-ipc so it retries at once. It approves that one push or call only. It does not ask first. Not shown for items whose session has ended or that are already approved |
| Copy | Copies the approve line ("approve push 1a2b3c4d") to paste into that session yourself |
| Cancel | Removes the held item and any approval, as typing "cancel push" or "deny" does, and tells the session not to retry. Does not ask |

The "Left by ended sessions" section starts with a row "Nothing will run these" and a button that clears all of them. It carries on past one that fails and names each one it could not clear. If a session has no message inbox, it sees the approval on its next prompt.

Approvals needs no macOS permission. The message to the session goes through claude-ipc when that is installed, and the gate trusts the files, never the message.

## Settings in depth

### Hiding tabs and sections

The Tabs group lists every tab except Settings and Approvals, under the name and icon of its space. Each row has a grip, an icon, the tab's name, a badge that reads on or off, and a note: "shown", "hidden", "all 4 sections shown" or "3 of 4 sections shown". Click a row to open it. Inside is "Show this tab", and, for tabs that have sections, one switch per section.

| Tab | Sections you can hide |
|---|---|
| Agents | Context |
| Usage | Claude, Codex |
| Hooks | Guards, Rules, Hook scripts |
| Ledger | Mistakes, Open proposals, Closed proposals, Checkpoints |
| Queue | Scheduled, Cron duties, Deploy queue, Open proposals |
| Library | Skills, Parked skills, Knowledge, Personas, Scripts |
| Machine | Session, Drives, Repos |
| Runtime | Databases, Services, Dev servers, Local models, Schedules |
| Claude MCP | Plugins, MCP servers, Project plugins, Project MCP servers |
| Controls | Sound, Display, Wi-Fi, Bluetooth |

The other tabs (Notes, Timers, Home, Remote) have one body and are shown or hidden whole. The section switches are disabled while their tab is hidden.

Hidden is never read. A hidden tab is not refreshed when the panel opens. A hidden section's source is not read: its helper script does not run, its files are not opened, and its network probes are not made. So hiding is also how you save work or avoid a permission prompt, since the Bluetooth list is never read when the Bluetooth section is hidden. When you bring a section back, it is read on your next visit.

One exception exists on purpose. While a timed flip is pending on a switch, Switchboard still reads the hidden sections that switch could belong to, so the timer can confirm it worked.

### Reordering the tabs

In Settings the tabs are listed under their space. Drag the grip on a tab row to change its place within its space; the row of tabs in the header follows at once, and the order is saved. A tab keeps its space, so a drag never moves it to another one. The header itself is not draggable. When your order differs from the default, a "Default order" link appears above the list and puts it back. A tab added in a later version lands after the tab it follows by default.

### Search

The search field in Settings matches tab names, section names, hover pages, the Now page items (their titles and their descriptions), "delay" and "notes folder". While you search, the grips are hidden and a tab whose section matched opens to just the matching sections.

### Hover pages

Lists every page of the hover card in its order, with a grip and a switch. Drag the grip to reorder the pages, and switch a page off to hide it. Timers, Controls and Local models start off. The last page still shown cannot be hidden, so the card always has one.

### Mouse-away delay

A slider from 1 to 15 seconds for how long the hover card stays after the pointer leaves the icon and the card. Scrolling over the slider moves it a second at a time.

### Now page

Five switches, one per item in the table under [The hover card](#the-hover-card). The defaults are Waiting on you, Problems and Running timers. Each row's note describes what it adds. Turning on "Dot on the icon" is what makes the dot appear.

### Notes folder

Shows where notes are saved (`~/Library/Application Support/Switchboard/notes` by default, with the note "the default"). Choose opens a folder picker labelled "Use this folder", where you can also create a folder. Notes already saved in the old place stay there, so moving them is a Finder job you do on purpose. Once you have chosen a folder, the note says "chosen by you; notes already saved elsewhere stay there", and a Reset button goes back to the default. Switchboard writes only your `.md` note files into a folder you choose, and keeps the note order in its own state folder so that nothing extra lands in yours.

## Permissions and privacy

### What macOS is asked, and when

| Permission | Asked when | Used for | If you say no |
|---|---|---|---|
| Bluetooth | The first time the paired-device list is read (see [Controls](#controls)) | Listing paired devices and connecting or disconnecting them | The paired-device list cannot be read. The rest of the tab is unaffected |
| Reminders | The first time you set a reminder on a note | Adding, moving and removing the one reminder that note owns | The note saves, with a red line saying how to allow it in System Settings |
| Location | Only if you click "Show name" on the Wi-Fi row | Reading your Wi-Fi network's name, which macOS hides from apps without it | The name stays hidden; Wi-Fi control still works |
| Notifications | The first time a timer starts | The banner and sound when a timer ends | Timers still ring in the app, and the Timers tab says so |

Switchboard never asks for anything at launch. A grant is filed under the app's code requirement, and `scripts/build.sh` signs with one that names the bundle id, so a grant survives a rebuild. Manage grants in System Settings under Privacy & Security, and notifications under Notifications.

### What Switchboard never shows

The Claude MCP tab never shows MCP keys or tokens: environment values are never shown, URLs show only their host, and credential-looking arguments are hidden. Details are under [Claude MCP](#claude-mcp).

### What it changes, and where

Switchboard is a reader first. The things it writes are all things you click:

- Your Claude settings: `~/.claude/settings.json` (plugin on/off, connectors, browser tools, and the three permission prompts), always read back after the write, always with a timestamped backup beside it, and never created if it is missing. A project's `.claude/settings.local.json` for project MCP servers.
- Guard files in `~/.claude`: Re-arm deletes a mute file; Approve writes a single-use approval file; Cancel deletes held items and approvals; the Warden switch writes or removes its pause file; policy changes go through the policy tool.
- Its own files: notes, and in `~/Library/Application Support/Switchboard` the bulb names, wake devices and a repository scan cache. Preferences (thresholds, tab order, hidden tabs, timers) live in macOS defaults under `io.github.alcatraz627.switchboard`. The log is described under Troubleshooting.
- Processes: pm2 and launchd services you start or stop, the power assertion for Keep Awake, and wake-on-LAN packets and bulb commands on your local network.

It reads a lot more than it writes: files in `~/.claude`, the git state of repositories under `~/Code`, launchd, pm2, ports on this Mac, and the local network for bulbs. It has no account, sends nothing to any server of its own, and the only links to outside sites are the two Usage page links, opened in your browser when you click them.

### A click can restore a protection, never remove one

This rule shapes every switch. Re-arming a muted guard deletes its mute file, but muting stays a deliberate act in a shell. Lifting a snooze and cancelling a held push or ask each add friction, never remove it. The one switch that weakens a safeguard, suppressing a Claude Code permission prompt, asks first in a dialog. Turning Wi-Fi or Bluetooth off asks first too, because it can cut you off. Approve is the click that lets a held push or call through: it covers that one item only, and it is your decision to make.

## Troubleshooting

### A timer rang but there was no banner

Notifications are off for Switchboard. The Timers tab shows "macOS has Switchboard's notifications off, so a timer rings here with no banner", and Open Settings takes you to the app's notification settings. Alerts set to "None" count as off. The chime plays for up to 30 seconds either way, and opening the panel stops it. The tab rechecks each time you open the panel, so a change you make in System Settings shows up on the next open.

### A permission was asked again

Grants are filed by the app's code requirement. Builds made with `scripts/build.sh` keep their grants across rebuilds. A copy built or signed some other way counts as a different app to macOS and asks again, and so does a copy in a different place if it is signed differently. Check the grant in System Settings under Privacy & Security.

### A group says it failed

Read the line. An amber "as of 12m ago · couldn't refresh: the reason" means the last read failed and the old values are still shown. A red line means there was never a value. Retry (or the reload arrow in the footer) reads it again. The reason is usually one of these: a helper took longer than its limit and was stopped, a tool such as pm2 or python3 is not installed or not on the PATH, launchd or macOS refused, or a file could not be read. The Problems badge on the hover card's Now page names the helper that failed (for example `gitscan.py`). The log line "probe failed, keeping the last value" has the same reason.

### An older version appears

Only one Switchboard runs at a time. When a copy starts, it looks for other running copies. If another is newer, the one that just started quits and leaves the newer one running. If the others are older or the same, it stops them. macOS can start the installed copy on its own, for example when you click a notification, because the click goes to whichever app owns the bundle id. The rule exists so that an older installed copy started that way does not stop a newer one you launched from a build folder. If you still see an old version, check which copy is running with `Switchboard --version`. The log records what happened ("dedupe: a newer copy runs as pid 123; leaving it running and quitting", or "dedupe: stopped 1 older instance(s)"). Headless runs, started with flags like `--dump`, are left alone.

### A tab is missing

Check Settings first, since it may be hidden. Agents is absent when the policy tool is not installed, Remote when csync is not, and Approvals whenever nothing waits.

### The panel shows old values

Click the reload arrow in the footer, or click the tab again. Values are read when the panel opens, except that the list tabs are not read again within 20 seconds of their last read. The Agents values and Claude usage also refresh every 30 seconds while it is open.

### Where the log is

`~/Library/Logs/Switchboard/switchboard.log`. It gets one line per event: launches, the panel opening and how long it took, each Machine read, timed flips, failed switches and helper failures. It rotates at 1 MB and keeps one backup, `switchboard.log.1`. To follow it live, run `scripts/build.sh --logs` from the repository, or `tail -f` on the file.

### Checking without a screen

Every surface can be checked headlessly. The commands below are for people who have the repository or the app bundle; they read only, except where noted. The full list is in [the architecture notes](../dev/architecture.md#headless-checks).

| Command | What it does |
|---|---|
| `Switchboard --version` | Prints the version |
| `Switchboard --dump` | Prints the Machine and Remote rows as text |
| `Switchboard --dump-policy` | Prints the Agents rows as text |
| `Switchboard --snapshot out.png --tab home --light` | Draws a tab to an image |
| `Switchboard --probe-timers` | Exercises timed flips by really flipping Keep Awake and putting it back |

Run it from `~/Applications/Switchboard.app/Contents/MacOS/Switchboard`, or from `build/Switchboard.app/Contents/MacOS/Switchboard` after a local build. The probes that write use a scratch folder, never your notes, timers or `~/.claude`, and `tests/run-tests.sh` runs them all.
