# Owner feedback, round 5 (2026-10-01): hover popover, notes, inputs, tabs, home

This file is the hand-off. The next agent resumes from it. The owner's words
are kept verbatim; the screenshots are gone after /clear, so what each one
showed is described in brackets.

## How the owner wants this worked (binding)

> note all of this down as explicit feedback, next session don't just jump into
> one-shot fixes. have a look at it structurally on the kinds of assumptions or
> neglect in the mental model you have for this, and what will an updated mental
> model be like (again, dont make it a spam list of fixes), but a general
> coherence expectation. Apply the updated mental model to these specific issues
> and see if it fixes them; if not then something is missing. Then, apply the
> mental model to the whole app, and see what other things can be improved or
> fixed. THen show me the final llist of all the fixes / changes to make; the
> list above is a must, and I will rule on the rest. You can do these fixes
> after the first audit itself. You may use /skeptical-review for both levels of
> audits. WRITE ALL OF THIS DOWN, the next agent will resume from this.

The order, then:
1. Name the assumptions and neglects in the current mental model of the app
   that produced these issues (not a fix list: a model).
2. Write the updated mental model as a coherence expectation.
3. Apply it to the must-list below; any item it does not explain means the
   model is missing something; revise.
4. Apply it to the whole app; collect further candidates.
5. Show the owner one final list: the must-list (do these) and the candidates
   (owner rules). The must-list may be built right after step 3's audit.
   /skeptical-review may be used for both audits.

## The must-list, verbatim

### Hover popover (the scroll-to-cycle quick pages, Sources/QuickPages.swift, Sources/Hover.swift)

- "There is no border below the title bar, the open icon can be better, the
  pills for the various tabs should have a small icon in them and be clickable
  (or I press a number to go to them)"
- "Also for the hover scroll tab, please remember the one that was open last.
  It resets and the new hover shows the same old one. If the same tab is no
  longer in the list then fall back to the first one but normally please retain"
- "In the actual hover popover, also add the scroll behavior to the title bar
  for that, do not let scrolling change the tab in the content below but the mac
  os top bar icon + the hover popover title section are fair game for scroll to
  tab. THe number pressing to change tab should also only work for the same
  crietia as hover (so editing an input field in the actual hover surface does
  not change tab)"
- "In hover preview section settings, allow reordering the list so it shows
  like that in the hover"
- "Suggest more candidates to add to the hover popover"
- [Image #53: the Limits page showed rows "5h", "week", "Codex Week",
  "Codex Week · gpt-reserve"] "claude limits are assumed to be default w labels
  and codex is called out explicitly, just show claude 5h / 7d and codex 7d (no
  reserve), make the label the <icon> <5h|7d)"
- [Image #54: the Now page showed a "3 wrong" chip, the Claude 5h/Week bars,
  and three warning lines: "refresh session index failed (exit 1)", "1 gate is
  off", "8 hooks have no event"] "the home tab now is just an unorganized spam
  that also shows claude limits; claude limits go to its own page, make this a
  two tier page with 2 x 3 grid of common access clicks for tabs/subtabs in the
  app (icon + small label, same as the sub-tab), and the second one is the
  standardized warn / error badge. Make the warns similar to the error visually
  and clikcing them opens the full dropdown and goes to the related item"

### Tabs and scrolling (main panel)

- [Image #56: the panel's space bar (Claude, Records, Desk, Mac, Around) and the
  sub-tab row (Agents, Usage, Claude MCP, Hooks, Library); red dots on Claude,
  Mac and Hooks] "allow mouse scroll on tabs and subtabs to change them back and
  forth, independent of each other and working consistently and avoid making it
  feel sluggish"
- "Why is Claude > Hooks showing a forever error when it shoould be a warn at
  best? We want proper usage of warn and error, I see an error bar all the time"
- "Is there a way to make the main dropddown open and tab/sub-tab switch more
  snappy? Don't remove the animation, it is the loading delay I can see it. Do
  not fuck up the actual capability or add race conditions; if it is not
  possible then say so."

### Notes (Sources/NotesView.swift, Sources/Notes.swift)

- [Image #57: a note row "Improve deck / deck.html" with link, copy, Aa, pin and
  chevron icons] "in the notes, the default copy only copies the body, the Aa
  icon is for the title; in case of only title only show the Aa title copy
  button, incase of only body only show the copy button; make both optional but
  at least one is requred; refuse to save if all is empty, the delete button is
  for that. Also allow each note to be tagged by a color similar to reminders,
  never show color names only color balls"
- [Image #58: the new-note composer expanded: an empty grey box with a white
  vertical scrollbar stub and four icons (collapse, check, clipboard, tray) in a
  row at top right] "new note expanded shows no placeholder + always show a
  scroll; expand should show title + subtitle buddy. Also pressing enter in the
  title should prepend the rest to the note body; need this behavior consistent
  in all places (new / edit), similar to notion I think (for new note UI, if
  collapsed then turn on expand and move the rest to body; if body already has
  something then just prepend it with a new line at the end, also the icons take
  too much horizontal space in expand mode, can they be stacked vertically in
  this case on expand?"

### Reminders (the Timers tab, Sources/Timers.swift) and inputs everywhere

- "In reminders, the title input bg is white (Unlike other places), need all to
  be standard design, and pressing enter starts the reminder (with or without
  the title) if the input is focused"
- "When opening the note or reminder tab, have the new input have input focus by
  default. If a note or a reminder title was expanded or being edited, retain
  that focus and do not give the new input focus in that case. Escape takes away
  focus but does not close a note. Escape takes away focus from the new input.
  Escape takes aaway focus from search inputs everywhere. Ensure search inputs
  have the standard search icon + terse placeholders, no word spam -> I think you
  need a standard input field component + a common component for notes editing
  that can be used for other things in the future"
- [Image #59: the Records > Ledger list (mistakes and proposals) with an expanded
  proposal showing Proposal, Kind, Tags, Filed; search placeholder "Search
  mistakes and proposals"] "for these explicit text surfaces, allow selecting
  text on it like a normal web page, and copy if cmd + c pressed. Keep the UI
  same"

### Machine and Controls

- [Image #60: Mac > Local models: Ollama "no models loaded" with an ok chip,
  Warm companion row with a download icon and "off", Memory pressure, mem-guard]
  "allow me to set the eviction policy in the ollama expand (not just a single
  button but everything that the actual tool supports)"
- [Image #55: Controls: Sound card "MacBook Pro Speakers 75%" with icons and a
  slider on its own row; Display card "Built-in display 35%" likewise] "these are
  taking 3 rows effectively, can be fit into 2 rows. Also allow scrolling on
  range sliders to jump back/forth by 5% units , ensure doesn't zoom away too
  much or move too slowly. Also ensure if the wifi / bluetooth / something
  else's name is too long it gets middle truncated -> global policy for overflow
  mitigation, middle truncate, do not do it too eagerly"

### Last

- "Once all is done, look into why the refresh session index is failing" (the
  Now page showed "refresh session index failed (exit 1)": a launchd job; see
  `Resources/lib/jobs.py` and App.problems()).

## What the agent that built round 4 already knows (context, not conclusions)

- The quick pages were built from a literal reading of the roadmap spec; the
  owner's feedback says the model was "pages of content", where the owner
  thinks in "navigation and status": the hover is a launcher plus a status
  strip, consistent with the panel's own spaces, sub-tabs and badges.
- Several items share one root: inputs, search fields, focus, Escape, text
  selection, number keys and scroll are handled per screen, not by shared
  components with one behaviour. The owner names this directly ("a standard
  input field component + a common component for notes editing").
- Warn vs error is decided per producer (problems() in App.swift), not by one
  severity policy; "8 hooks have no event" renders as an error everywhere.
- Panel open and tab switch latency: PolicyStatusController.show() opens on
  loaded state then refreshes; the visible delay needs measuring (dlog prints
  "policy panel shown in N ms") before claiming a fix.
- Test surface: `bash tests/run-tests.sh` (98 passed at b966434),
  `--snapshot --tab <tab>`, `--snapshot-quick <png> --page <p>`, `--probe-quick`.
  A real pointer or scroll test needs the owner or approved desktop automation.

## Step 1: what the old model assumed (2026-10-01, session ce9de2fb)

Six assumptions produced these issues. Each is grounded in the code as it
stood at 41a6292.

1. **Every screen is its own small app.** Inputs, focus, Escape, scroll and
   key handling are decided screen by screen. Seven files create their own
   text fields (`rg -c "TextField\(|TextEditor\("`: NotesView 5, Timers 2,
   PolicyPanel 2, App 2, Lights, WhenPicker, DesignKit). Escape means four
   different things in four places: clear the search (PolicyPanel.swift:1622),
   cancel a rename (Lights.swift:348), end an edit (Timers.swift:263), close an
   ask (PolicyPanel.swift:686). Nothing owns "what Escape does", so each new
   screen invents it, and the owner meets the differences.
2. **The hover card is a stack of content pages.** It was built from the
   roadmap's wording: dots for position, a reset to Now on every hover
   (Hover.swift:152), scroll only over the icon (Hover.swift:116). The owner
   thinks of it as a small version of the panel: the same navigation grammar
   (icon tabs you click, scroll or number-key through, remembered between
   visits) wrapped around a status strip.
3. **Severity belongs to whoever reports the problem.** `problems()`
   (App.swift:1725) returns text and a tab, no level. Every consumer paints
   it red: ProblemMark (PolicyPanel.swift:597), the "N wrong" chip
   (PolicyPanel.swift:1291). So a configuration nit ("8 hooks have no event")
   looks exactly like a broken job, forever.
4. **Labels name the data source, not what the owner tells apart.** Limits
   read "5h", "week", "Codex Week", "Codex Week · gpt-reserve": Claude was
   the unnamed default and Codex the named exception, and a reserve window
   the owner never acts on got a row.
5. **Content takes its natural shape, then overflows however it can.** The
   Sound and Display cards lay out in three rows because the slider got its
   own row; truncation is decided per view, often by tail-cutting.
6. **Where you were is throwaway.** The hover page resets, opening Notes or
   Reminders does not put the cursor anywhere, an edit in progress is not
   protected from a tab switch's focus change.

## Step 2: the updated model, as a coherence expectation

The app is **one surface with one grammar**, seen through three windows (the
menu-bar icon, the hover card, the panel). The owner should be able to learn a
behaviour once and find it everywhere.

- **Navigation.** Any strip of tabs (space bar, sub-tab row, hover pills) is
  icon plus short label, clickable, moves on scroll when the pointer is over
  the strip itself and never over content, answers number keys whenever no
  text field holds focus, and remembers its position, falling back to the
  first entry when that entry is gone. The owner decides the order.
- **Input.** One text-input component and one title-plus-body editor. Same
  background everywhere; Enter does the field's main action; Escape drops
  focus (and never closes or deletes anything); opening a tab focuses its
  "new" input unless something else is mid-edit. Search fields carry the
  search icon and a one- or two-word placeholder.
- **Severity.** Every problem carries a level. Error means broken and needing
  action; warn means degraded or a configuration nit. Both use one badge
  shape and differ only in colour, and a click opens the panel at the item.
- **Labels.** A label names the distinction the owner makes; an icon carries
  "whose" (Claude, Codex) so the words can stay short and symmetric. Colour
  is shown as colour, never as its name.
- **Space.** Fit the slot first. Overflow is a middle truncation, applied
  only when the full text does not fit.
- **Scroll on a thing adjusts that thing.** A tab strip steps through tabs,
  a slider steps by 5%, content scrolls content. No surface steals another's
  scroll.
- **Text is a document.** Read-only text surfaces are selectable and copy
  with Cmd+C, with no visual change.
- **Speed is measured, not felt.** A latency claim comes with the dlog
  timing before and after.

## Step 3: does the model explain the must-list?

| Must item | Explained by |
|---|---|
| Hover: no border under the title, better open icon, pills with icons that click or take a number | Navigation |
| Hover: remember the last page, fall back to the first | Navigation (position is remembered) |
| Hover: scroll over title bar and icon only; number keys not while typing | Navigation + Input |
| Settings: reorder the hover list | Navigation (owner decides the order) |
| Suggest more hover candidates | Step 4 (whole-app pass) |
| Limits: Claude 5h / 7d, Codex 7d, icon labels, no reserve | Labels |
| Now page: 2x3 launcher grid plus one standard warn/error badge row | Navigation + Severity |
| Main panel: scroll on tabs and sub-tabs independently | Navigation, Scroll |
| Hooks "forever error" | Severity |
| Snappier panel open and tab switch | Speed is measured |
| Notes: copy buttons follow which fields exist; refuse empty; colour tags as balls | Input (one editor), Labels (colour as colour) |
| New-note composer: placeholder, no stray scrollbar, Enter in title moves the rest to the body, icons stack | Input (one editor) |
| Reminders: standard input background, Enter starts | Input |
| Focus on tab open, keep an edit's focus, Escape drops focus everywhere | Input |
| Select and copy text in Ledger and similar | Text is a document |
| Ollama: every eviction setting the tool supports | **Not explained.** See revision below. |
| Sound and Display in two rows; slider scroll by 5%; middle-truncate long names | Space, Scroll |
| Why "refresh session index" fails | Severity (a failing job is a real error, so find its cause) |

**Revision.** The Ollama item is not covered by any of the above: the owner is
saying a control that wraps a tool should expose what the tool can do, not one
chosen button. Added to the model:

- **A control mirrors its tool.** Where the panel wraps a tool's setting, it
  offers every value the tool supports, read from the tool where possible.

With that, every must item maps to the model. Step 4 (apply it to the whole
app and collect candidates for the owner) has not run yet.

## Build order

1. Hover group (this session's goal): remembered page with fallback, scroll
   over title bar and icon only, number keys gated on text focus, icon pills
   that click, a border under the title, a clearer open icon, Limits labels.
2. Severity (a level on every problem, one badge, Hooks becomes warn), then the
   Now page grid, which needs both Navigation and Severity in place.
3. Shared input and editor components, then Notes, Reminders, focus and Escape.
4. Panel tab scroll, slider scroll, Controls layout, middle truncation.
5. Ollama eviction settings, text selection, latency measurement, the session
   index job.

## Status

- Step 1 done in a449e38: hover pills, remembered page, title-bar scroll,
  number keys, Limits labels (`--probe-quick`).
- Step 2 done in 85e3a70: problem levels, one badge, Now launcher grid
  (`--probe-visibility`). Defaults taken without asking: the grid's six tabs
  are Agents, Hooks, Notes, Timers, Controls, Machine; warnings never light
  the icon dot; the card now opens on every hover because Now always has the
  launcher.
- Not yet seen with a real pointer: title-bar scroll, number keys (they need
  a click into the card first, so a hover never steals the keyboard), badge
  click landing on the searched rows in a live panel.
- Step 3 done in 27ef07f: Sources/Inputs.swift (InputRules, EditorText,
  NoteSheet, ColorBalls, EditingState) under Notes, Timers and search
  (`--probe-notes`). Defaults: collapsed composer Enter now opens the body
  instead of saving (owner's spec); ⌘↩ or the check saves. Search Escape
  keeps the text. Lights rename and the policy ask field keep their own
  Escape (cancel), which also drops focus.
- Not yet seen live: keyboard focus landing on tab open (depends on the
  panel re-running onAppear when it reopens), Escape not closing the panel.
- Step 4 done in f744aaa: Sources/ScrollSteps.swift (ScrollStepper shared by
  the hover card and the panel, ScrollTargets registry, one panel scroll
  monitor), space bar and tab row step independently (one tab per 28 pt of
  swipe or per wheel notch, 0.12 s apart, stop at the ends), sound and
  brightness sliders 5% a notch (up raises), Controls two rows, `nameFit`
  middle-truncates names only (prose still wraps). `--probe-quick`.
- Not yet seen live: scroll direction feel on a real wheel and trackpad.

- Step 5 done in e141587 and 94e75e6: Ollama keep-loaded menu, Unload all,
  companion Reload, default eviction read-only; models.py `keep` verifies
  the model actually loaded. Selectable text in opened details. List tabs
  read at launch and not re-read within 20 s (measured reads: plugins 603 to
  878 ms, rules 306 ms, library 129 ms, ledger 60 ms, queue 29 ms;
  `--time-tabs`). Settings "Hover pages": drag to order, switch to hide.

## Step 6: the final list (for the owner)

Every must item is built, except the session-index fix (below), which is a
gcc change awaiting approval. Not seen live yet: title-bar scroll, number
keys, badge click landing on its rows, focus on tab open, Escape not closing
the panel, scroll direction feel, the Ollama expand (the headless snapshot
does not build the Local models group).

Candidates found while applying the model, for the owner to rule on:

1. More hover pages (asked for): Timers (running timers with +1 min and
   stop), Controls (volume and brightness sliders, Wi-Fi and Bluetooth
   switches), Repos (unpushed and uncommitted counts, open in editor),
   Local models (what is loaded, keep or unload). Each is a page in the
   Settings list, off by default.
2. Inputs still on their own rules: the Lights rename field and the policy
   ask field cancel on Escape; the When picker's typed field keeps the white
   rounded-border look. Move them onto the shared input.
3. The lm suite's `warm` reports success when Ollama refuses (curl -s exits
   0 on an error body). Switchboard now checks; the tool itself is in
   ~/Code/local-models and is unchanged.
4. The test suite writes "catalog probe read in 0 ms" lines into the owner's
   real Switchboard log. Point test runs at a scratch log.
5. The old hover preview path (HoverPreview, hoverLines, --snapshot-hover)
   only serves its own test now. Remove it, or keep it as the fallback.
6. Colour at note creation: the composer has no colour balls; a colour is
   picked after saving.
7. Middle truncation is applied to Controls names only. Device, repo and
   model names elsewhere (Machine repos, Runtime services) could use it too.
8. Uppercase section labels (still awaiting the sentence-case ruling).

## Why "refresh session index" fails (investigated 2026-10-01)

`com.alcatraz.refresh-session-index` runs
`~/.claude/scripts/refresh-session-index.sh`, which imports `crawl` from
`~/.claude/skills/scan-sessions`. Commit a096555 (2026-08-27) moved that skill
to `~/.claude/skills-parked/scan-sessions/`. Every run since dies with
`ModuleNotFoundError: No module named 'crawl'`, written to
`~/.claude/assets/scan-sessions/refresh.log` (the launchd err log stays empty
because the script redirects Python's output). Last good run: 2026-08-26,
total_sessions=6708. The index keeps sessions whose transcripts Claude Code
later deletes, so every missed day risks losing the oldest unindexed ones.
Fix is a gcc change, the owner's to approve: point the import at
`skills-parked/scan-sessions`, or unpark the skill, or retire the job.
