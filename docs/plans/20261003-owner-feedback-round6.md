# Owner feedback, round 6 (2026-10-03): audit, then one list

Method as in round 5: name the assumptions behind the asks, state the model that replaces them, check it explains every item, apply it to the whole app for candidates, then one list. Nothing below is built yet.

## The owner's items

| # | Ask (owner's words, trimmed) |
|---|---|
| O1 | The hub in Switchboard's own window is "MUCH better than in chrome": make it the default. On the logo: click opens the hub (board), middle click opens it in Chrome, hover triggers a refresh. In Chrome the logo works as a normal new-tab link. |
| O2 | Explore power-user gliding with keys and mouse scrolls across hub and Switchboard. |
| O3 | Hover card: an option to always show a permissions card under the current page, divider-separated: one line per agent permission, and a button in that card's title bar that goes to the full hover page. |
| O4 | Lights: an active row gets an intensity slider right of the bulb (wheel-steppable), the % at the far right. Clicking the row turns that bulb off. Middle click on a row (active or not) opens the bulb in the full window and flashes it. A bulb drops to a chip only after 2 hours off. |
| O5 | "Flash on arrival" for every in-app link, globally. |
| O6 | Notes and timers need a better power-user UX. |
| O7 | Validate: can sections, tabs or subtabs become macOS widgets? |
| O8 | A global size setting: sm (today), md (wide monitor), lg (screen share). All surfaces: menu-bar icon, icons, text, inputs (inputs scale less), kept coherent. Also: a /gcc-proposal to make this the standard size calibration for any UI project, encoded in the ui skill and every UI agent's guidance. |
| O9 | Research and propose an animation skin for the hub and Switchboard, coherent with content, identity and actions; later /create-skill ui-animate and wire into /ui and /router:ui. |

## What the asks have in common

Five assumptions in today's build explain all nine items.

1. **A page is a fixed layout, not a set of sections that can be shown anywhere.** O3 (permissions under any page), O7 (a section on the desktop) and O8 (any section at any size) all ask to render the same section in a new place or size. Today each hover page and tab draws its own rows. Model: one registry of sections, each drawable on its own, with the place (tab, hover page, pinned card, desk panel) and the size passed in.
2. **The mouse has one button and the wheel only scrolls.** O1 (middle click, hover refresh), O4 (middle click, wheel on slider) and O2 all assume more. Model: one input grammar, the same everywhere. Left click does the obvious thing; middle click opens the thing in its fuller home; the wheel over a value steps it; hovering a source refreshes it; number keys and arrows move between peers.
3. **A link lands on a tab, not on a thing.** O4 and O5: after a jump the eye has to search. Model: every in-app link is a reveal: open the place, scroll the thing into view, flash it once. Badges, Sessions rows, Approvals rows and search results all use it.
4. **Prominence is fixed, not earned by use.** O4 (a bulb stays a row for 2 hours after it was on). Model: recent use keeps a thing prominent for a while; the same rule fits notes (recently edited) and timers (recently used presets).
5. **Size and motion were never designed, only defaulted.** O8 and O9. Model: size is three named scales over one set of tokens (text, icon, control, spacing), with inputs and icons stepping less than text; motion is a small vocabulary tied to meaning (arrive, leave, change, attention), not decoration.

Check: every item maps to at least one model. O6 (notes, timers) maps to 2 and 4; it gets the same grammar plus a proposal per surface in the build round.

## O7, answered with evidence

**Partly feasible, and not the way the question assumes.** Real macOS widgets (WidgetKit) need an app extension built by Xcode, sandboxed, sharing data through an app group whose entitlement needs a provisioning profile. This Mac has only the Command Line Tools (`xcodebuild` is absent) and one self-signed identity ("Xenon Doctor"), so that path needs Xcode installed and a free Apple developer team first, and is UNCONFIRMED until tried. Even then, widgets are snapshots refreshed on a budget: buttons and toggles work through App Intents, sliders and live scrolling do not, and the largest size cannot hold a whole tab with its subtabs.

**What gets you the intent without those limits:** desk panels. Switchboard opens any section, page or tab in a small borderless window pinned to the desktop layer (below normal windows, on every Space if wanted). They are live, take every click, wheel and key the panel does, follow the size setting, and need nothing new in the toolchain. Real widgets could come later, for glanceable read-only sections, if Xcode is ever installed.

## Candidates found by applying the model (owner rules)

| # | Candidate | From model |
|---|---|---|
| C1 | Wheel over any Switchboard slider steps it (already true in the panel); extend to the hover card's Controls page and the new bulb slider. | 2 |
| C2 | Middle click on a Sessions row opens the transcript in Chrome; on a badge, opens its tab in the full panel. | 2 |
| C3 | Hover on a Sessions row or the Approvals page header triggers a rescan, as O1 asks for the logo. | 2 |
| C4 | Reveal-and-flash for the Now page badges, Approvals rows, search hits and hub card lines (the hub-round item about opening a transcript at a line is the same idea). | 3 |
| C5 | Notes: recently edited notes stay as rows, older ones become chips, like bulbs. | 4 |
| C6 | Desk panels for the Sessions page and the permissions card first. | 1 |

## Plan and cost

Weekly usage is at 100%, so each round is named with its cost before it starts.

| Round | What | Size |
|---|---|---|
| A | Input grammar + reveal-and-flash as shared pieces, then O1, O4, O5, C1 to C4 on top | one long session |
| B | Size scale (O8): tokens, three scales, every surface, render checks at each scale | one long session |
| C | Section registry + O3 permissions card + desk panels (O7 answer) | one long session |
| D | Notes and timers power-user pass (O6) | half a session, after A |
| E | Animation strategy (O9): research report only, no build | one research run with sub-agents; costed before it starts |
| F | gcc: size calibration as a standard (O8 second half): proposal filed now, then the ui skill and agent guidance | small |

Order: A, B, C, D, then E and F. A first because B, C and D all reuse its grammar.
