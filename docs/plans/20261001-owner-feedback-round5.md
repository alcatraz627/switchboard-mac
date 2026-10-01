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
