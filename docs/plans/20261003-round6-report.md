# Round 6 report (2026-10-03)

Everything in the round 6 plan (`docs/plans/20261003-owner-feedback-round6.md`) is built, tested, committed and installed, except two things that need you: the pushes, and the live checks listed under "Not checked live". The suite is 120 passed, 0 failed (1 skipped by design, the Keep Awake timer probe).

## What shipped

| Round | What you get | How it was checked |
|---|---|---|
| A | Middle click opens a thing in its fuller home (a bulb or an approval in the panel, a session or the board in the browser, a badge's full tab). Every in-app link lands on its row and flashes it. Hub links open in Switchboard's own window; middle or Command-click goes to the browser; hovering the hub logo refreshes. Hover Bulbs: a lit bulb has an intensity slider the wheel steps, the % at the right edge, a click turns it off, and a bulb stays a row for two hours after it goes off | probe checks for every rule; bulbs page rendered against your real bulbs; suite |
| B | Settings > Size: Small, Medium, Large. Every surface moves together, including the menu-bar icon (capped to the bar's height). Text grows most, icons less, inputs least | probe checks; Sessions page and Settings rendered at Medium and Large and read back; suite renders both |
| C | Desk panels: pin any hover page or panel tab to the desktop (pin icon in the hover card's and the panel's header). Desktop layer or above windows, every Space, remembered. Settings > Under every page: a waiting-on-you card under every hover page, a button to Approvals | desk panel and card rendered; probe checks for save and naming |
| D | Timers: type "25m tea" and Enter starts it; the last five timers come back as chips; the wheel over a running timer on the hover card moves it a minute; middle click opens it in the tab. Notes: Shift-Command-Return saves and pins; a note edited in the last two hours stays a row on the hover card | probe checks (one found a real parse bug, "90s" read as 9 minutes, fixed); Timers tab rendered |
| E | Animation direction memo: `docs/plans/20261003-animation-direction.md`. Four verbs (arrive, leave, change, attention), the hub keeps its locked tokens and gains choreography, the Mac adopts the same curve and two speeds and honours Reduce Motion. No build | three of its cited numbers re-measured |
| F | The sm/md/lg standard in `~/.claude`: `conventions/visual-design.md` and the `/ui` hand-off | committed with only this session's lines staged |
| G | An independent test pass: 16 findings, 14 fixed, 1 not a defect, 1 parked | `.claude/output/20261003-round6-test/findings.md` |
| H | The sweep around the changes found 4 misses, all fixed: every slider now rises when scrolled up (the hover card had it backwards); the panel's bulb and Usage sliders take the wheel; the notes editor and AppKit text follow the size setting | suite |

## Not checked live (UNCONFIRMED)

- A desk panel on your real desktop: rendered headless only, never opened on your screen.
- A WebKit middle click on a hub link: the button number is 4 by WebKit's source; untested in a real window.
- The bulb slider's wheel on real bulbs: rendered, not turned.
- Large size on the real menu bar: rendered headless, not seen in the bar.

## Parked for your review

- ScaledRoot redraw order could drop a middle-click target until the next layout (finding 16, unconfirmed).
- The animation memo's direction (round E) needs your ruling before any motion is built.
- `pages.md` in `~/.claude` is not tracked by git, so its size row lives on disk only.
- The ipc wake-up continuity proposal (prop-20261002-190541-c4), task #5.

## Memory

Switchboard was reinstalled many times tonight, so the sampler's trend is in pieces per build. 0.4.0 settled at 192 MB. Every build since about 03:00 reads 134 to 138 MB (`memwatch-0.4.tsv`, last rows). The sampler ends about 04:35.
