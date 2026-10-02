# What Switchboard reads from this project

Switchboard's Sessions card depends on this project in two ways: it runs the scanner, and it opens hub pages. This page lists exactly what it relies on, so a change here that would break the card is visible before it ships. Switchboard's suite checks the scanner's fields on every run (`--probe-sessions`).

The coupling runs one way. Switchboard reads; nothing here reads Switchboard. Styling never crosses: the hub and the macOS card are separate design systems.

## The scanner

Switchboard runs `lib/scan.sh --quick` every few seconds (and the full scan about once a minute while the card is open) and reads these fields from each row of `live`:

| Field | Used for |
|---|---|
| `session_id` | identity; the transcript link `/s/<session_id>` |
| `pid` | identity |
| `name`, `cwd`, `cwd_short` | the row's name and the copied path |
| `attention` | the group: `needs_you`, `working` or `idle` |
| `status_since` | how long it has waited or worked |
| `session_state.state`, `session_state.detail` | the working verb ("Bash", "Thinking") |
| `last_reply` | the hero card's message, shown whole |
| `last_prompt`, `model`, `git_branch`, `cost_usd`, `input_tokens`, `output_tokens` | the hover detail and the spend total |
| `statusline.ctx_remaining`, `statusline.rss_mb`, `statusline.focus_file` | the context bar and the hover detail |
| `ipc.alias` (`ipc` may be null) | the copied ipc id |

`attention` is the one definition of the three states. Both the card and the hub board group by it, so a session reads the same in both. The rule lives in `attention_of` in `lib/scan.sh`.

Renaming or removing any of these fails Switchboard's suite. Adding fields is always safe.

## The hub

| Route | Used for |
|---|---|
| `GET /healthz` on 127.0.0.1:5400 | is the hub up; Switchboard starts it with `lib/hub.sh restart` when it is not |
| `GET /s/<session_id>` | a session's transcript, opened in a Switchboard window |
| `GET /` | the board, opened in the browser from the card's Hub button |
