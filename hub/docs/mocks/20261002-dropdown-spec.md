# Sessions dropdown: owner's ruling, 2026-10-02

Mock: docs/mocks/20261002-dropdown-variants.html. Owner picked variant D (focus first).

## Layout (variant D)

- Status strip: "2 need you · 3 working · 2 idle · $41 today", each part in its own colour and shade (waiting yellow, working green, idle grey, spend neutral), and "4s ago" right-aligned in very light grey (the last update).
- Hero card for the most urgent session: name, "waiting 20m", the full last message (wraps, never "…"). Simpler than the mock: no heavy tinted fill; proper macOS styling (system colours, materials, SF Symbols). Buttons carry icons.
- Every other session as a one-line row, grouped Needs you, Working, Idle.
- Idle = the agent is still open in a terminal (process alive). Always shown, never hidden. Liveness by pid every scan: no false negatives; a closed terminal disappears on the next scan.

## Row behaviour

- Click a row (or the hero): open the session's HTML transcript page (hub /s/<sid>/).
- Three small icon buttons at the right of each row, and only these: focus the terminal, copy the session's path, copy the session's ipc id.
- Removed: VSCode, Terminate, PID, Finder, Copy resume command.

## Hover detail card

- Keep the card (path, branch, model, context, tokens, cost, memory, last prompt, focus file).
- No buttons in it; the three actions live on the row.

## Bottom row

- Remove New, More, Recent sessions, Settings, and the Switchboard link. Past sessions are read in the hub.
- What remains: Hub (opens the board).

## Ruling: fold the dropdown into Switchboard (owner, 2026-10-02)

- Switchboard gains a "Sessions" hover page (variant D, first page) and shows the live count on its icon.
- The claude-instances menu-bar app retires.
- claude-instances stays a separate project and becomes the sessions service: scanner, hub server, board and transcript pages, still serving the phone when Switchboard is down.
- The coupling is one-way (Switchboard reads the hub) and made explicit: a contract doc in claude-instances listing the routes (/healthz, the session feed, /s/<sid>/) and the feed fields Switchboard uses, and a contract probe in Switchboard's suite that reads a recorded feed sample and fails loudly when a used field disappears.
- Revisit a monorepo (still two processes) only if paired commits across both repos become routine.

## Owner's ruling, round 2 (2026-10-02)

1. Two projects, one repo is fine (two repos only if the agent insists). Runtime must not feel disjoint. Switchboard owns the macOS sessions card; the hub owns rich reading, highlighting and searching. Switchboard may take the card down; the hub keeps working on its own.
2. Keep it simple. The card's job: one-click status of everything up and running, plus basic access (focus terminal, copy path, copy ipc id). The hub's job: rich presentation and history; no focus-terminal there; no history in the card. Separate schemas are fine if each is designed for its use case and they stay coherent (same session id, same state words).
3. "Claude integration" means: Claude's permission prompts arrive in Switchboard to answer, Claude's knobs are set from Switchboard's agent settings, Claude's usage shows in Switchboard. Not full device access.

### The two use cases, enumerated

Sessions card (Switchboard, macOS):
- per live session: session id, display name, state (needs you, working, idle) and since when, the last thing Claude said (hero only), working verb, context percent, cwd path, ipc alias, a terminal handle to focus (pid or terminal tab), liveness (pid alive each scan).
- aggregate: counts per state, spend today, time of last scan.
- never: history, transcript text, tool calls, chapters.
- source: the local scan output directly, not the hub, so the card works when the hub is down.

Hub (web, any device):
- per session (live and ended): transcript turns, chapters, tool calls and results, search index, per-turn tokens and cost, model, branch, highlights.
- board: live grouped by state, recent ended sessions, filters, search.
- never: focus terminal or other Mac-local actions.

Coherence: both use the same session id and the same state words and thresholds (one definition of needs you / working / idle in the scanner), so a session reads the same in both.

### Claude integration, what exists and what is missing

- Usage: exists (Usage tab, Limits hover page).
- Knobs: exists. The owner means the hook-guard allow / ask / deny settings and permission approvals Switchboard already has (Agents tab, Approvals), which are global and durable. Do NOT add controls for Claude Code's own settings (model, effort and the like); those are local and ephemeral and easy to find.
- Permission prompts: exists for held pushes and policy asks (Approvals); missing: Claude Code's own tool-permission prompts (a PermissionRequest hook writing a request Switchboard can answer, the same nonce-file pattern as pushes).

## Work plan for the next session (owner-approved shape, 2026-10-02)

Reference inventory: /Users/alcatraz627/Code/Claude/switchboard-mac/.claude/output/20261002-sweeps/claude-instances-references.md (one live break: Switchboard AppSupport.swift:136-139 hubScript lookup; everything else port-only or retires with the bar).

Step 1. Sessions card in Switchboard (variant D, as ruled above).
- Read the local scanner output directly (claude-instances lib/scan.sh JSON), not the hub; one state definition (needs you, working, idle) shared with the hub.
- New QuickPage "sessions" first in the hover page order; status strip with per-state colours and "4s ago" right in light grey; hero card for the most urgent (full message wraps, icon buttons, macOS system styling); one-line rows grouped; row click opens hub /s/<sid>/; row icons: focus terminal, copy path, copy ipc id; hover detail card without buttons; bottom row only Hub.
- Live count on Switchboard's menu-bar icon.
- Probes: state grouping and ordering, hero choice, idle liveness (pid gone drops the row on the next scan), and a contract check on the scan JSON fields used.
- Verify live with the pointer like round 5 (screenshots read back).

Step 2. Retire the claude-instances menu-bar app.
- launchctl bootout dev.claude-instances.menubar, trash ~/Library/LaunchAgents/dev.claude-instances.menubar.plist (confirm with the owner first; it is a deletion), leave native/ in the repo marked retired or remove it in the move.

Step 3. Hub under pm2, like Kanban and Decision Pages (owner ruling).
- pm2 process "session-hub" running lib/hub-server.py on :5400 (keep the port; hub.sh start/stop/restart becomes a thin pm2 wrapper so existing callers keep working).
- Switchboard Runtime > Services: Session Hub row with Start/Stop and a new "Start at login" toggle. Build the toggle once for all three pm2 services (Kanban, Decision Pages, Session Hub): what pm2 resurrects at login is the saved process list (pm2 save) plus pm2's own startup agent; check whether pm2 startup is installed before relying on it; the toggle must reflect real state, not a stored preference.
- Probe: toggle reads back the real pm2 saved list.

Step 4. Move the hub into the Switchboard repo (one repo, two projects, two processes).
- git subtree or history-preserving move of claude-instances (minus native/) into switchboard-mac/hub/ (name to confirm); re-point AppSupport.swift hubScript to the new folder (keep the old path as fallback for one release); update the docs that name the old path (list in the inventory) and the i-dream hub.sh pattern only if the script is renamed; run both suites; open board and a transcript from Switchboard.
- Do NOT move ~/.claude/widgets/ sibling data files (.limits.json etc.); they stay.

Step 5. Claude Code permission prompts in Switchboard Approvals.
- A PermissionRequest hook writes the request; Switchboard shows Approve / Deny; the answer returns by the nonce-file route pushes already use. Policy panel rules decide what may be answered there.

Not in scope: new knobs for Claude Code's own settings (model, effort); a big shared schema; the spine.

## Owner's direction beyond this build (2026-10-02, verbatim intent)

- Switchboard, csync and the csync Android app are meant to meld together (still separate projects) so context, actions, threads and data are shared across all the owner's devices and Claude is aware of all of it.
- Single owner, single system: isolation for its own sake is not the goal. If the hub is down and it is needed, decoupling does not help; the answer is availability (supervision, auto-restart), not tolerance.
- Design: the hub's web design and the macOS components stay two separate design systems, merged or not. The contract carries data only, never shared styling.
- Agent's pushback, recorded for the ruling: (1) keep separate processes for build-loop safety, not production tolerance: agents rebuild Switchboard many times a day (about 15 installs on 2026-10-02 alone), and an embedded hub would drop the phone's pages on every one; (2) grow the shared contract from real callers (session feed first, then the next thing a second device needs, likely held approvals over csync), not a big up-front schema; (3) every action Claude or another device can take through the shared layer goes through the policy panel's allow / ask / block rules from the first action.
- Proposed next piece (not started, needs its own design doc and the owner's ruling): one "spine" (local service plus a versioned schema for sessions, threads, actions, context, events) that every surface reads and writes; csync as its transport across devices; Claude reaches it through the same API. Comes after the Sessions page, which does not depend on it.
