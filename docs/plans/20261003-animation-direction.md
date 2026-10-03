# Animation direction: the hub and Switchboard (round 6 E)

> "I want to /pick-skill reseearch and propose an animation skinning over both the hub and the mac os widget. Devise a strategy for this thoroughly, all should be coherent and relevant to the content and product and visual identity and affordance / mapping / mental model / actions / associations, on all levels." Also: "the html view transitions in the hub pages is crude, explore adding more elements and animations to those".

**Ruling (owner, 2026-10-03):** "Yes these animation directions look good." Approved as written; build P1 to P6.

Repo f308761. Evidence: `.claude/output/20261003-0325-animation-direction/research-sheet.md` (rows cited below as R, H, V, K, M, X, W). No build in this pass.

## The direction: motion says what happened to a thing

Every animation answers one question the person would otherwise have to work out: where did this come from, where did it go, what changed, or what needs me. Four verbs, nothing else moves. The hub and the Mac app keep separate looks (R9, one product, two design systems) but share the verbs, the curve and the two speeds, so a session that arrives, works and waits feels the same in a browser and under the menu bar. Motion never carries meaning alone (W1): every animated state also has a static form, which is what Reduce Motion shows.

## The contract: four verbs

| Verb | Means | Hub today (keep) | Mac today | Mac, proposed |
|---|---|---|---|---|
| **Arrive** | A thing came into view because of you or because it is new | `fresh` lift 5 px, 260 ms (K3); `hpkin` (K5); `open` (K7) | `.transition(.opacity)` only (M4, M6) | Lift 4 pt plus fade, the slow speed |
| **Leave** | A thing went away, to somewhere you can name | crossfade only (V3) | none | Fade plus shrink toward where it went (a pinned note toward the pin) |
| **Change** | A value moved: a count, a state, a percentage | colour transitions, fast speed (K13) | none; numbers jump | Numeric text transition on counts and percentages; state dot crossfades colour |
| **Attention** | Look here, now: a link landed, something waits on you | `flash` single ring 1.1 s (K9); `pulse` on working (K1) | two-pulse fill 1.5 s (M10); no aliveness | One shape on both: the hub's ring, two beats; working sessions get the hub's slow pulse on their dot |

| Token | Hub (R9 locks these) | Mac, proposed |
|---|---|---|
| Curve | `cubic-bezier(.2,0,0,1)` (H1) | `.timingCurve(0.2, 0, 0, 1)` as one `Motion.ease` |
| Fast | 130 ms (H1) | 0.13 s, `Motion.fast` |
| Slow | 260 ms (H1) | 0.26 s, `Motion.slow` |
| Reduced motion | page-wide kill (H2) | `@Environment(\.accessibilityReduceMotion)` turns every verb into its static form |

The Mac's seven ad hoc durations (0.12 to 0.4, M1 to M10) collapse onto the two speeds. The values are copied from the hub so neither surface retunes; that is the rule R9 set, applied to the side it did not cover.

## Per problem

**P1. Hub page changes look crude (R3).** Direction. Today a page change is a 220 ms crossfade of the whole page with one named element per side (V3, V4); everything else snaps. Proposed: name the session card's state dot, title, cost and context bar on the board and the same four on the transcript header, so they travel to their new places (V5 already does this for the title alone); the board's other cards leave with a short fade while the transcript's body arrives with `fresh`. Going back reverses it, and the card you came from flashes (K9) so the eye lands. Falsifiable: on a click from board to transcript in Chrome 126 or later, exactly the named elements move and nothing else animates longer than the slow speed; check by recording with `--force-prefers-reduced-motion` off and on (W2). Firefox has no cross-document transitions (W2): it gets today's instant change, which is acceptable.

**P2. Smooth scrolling everywhere (R3).** Direction. Every scroll the app makes on the person's behalf (jump to a line, back to the card, new tail) uses smooth scrolling; scrolls that keep position during a live update stay instant (H5, deliberate). The gap: the smooth calls ignore reduced motion (H4). Falsifiable: `rg -n "behavior: 'smooth'" hub/lib` returns only calls that go through one helper that checks `prefers-reduced-motion`.

**P3. The Mac app has no shared motion and ignores Reduce Motion (M12, X5).** Direction: a `Motion` enum beside `Scale.swift` with the curve and two speeds, every `withAnimation` routed through it, and Reduce Motion honoured. Falsifiable: `rg -n "withAnimation\(\.ease|duration:" Sources` returns only `Motion.swift`.

**P4. A working session does not look alive on the Mac (X2).** Direction: the Sessions page's working dot pulses at the hub's 2 s pace (K1), stopping under Reduce Motion; needs-you dots stay still, because waiting is not activity. Falsifiable: a render of a working row at two times shows the ring at different sizes; a needs-you row does not.

**P5. Two different flashes (X1).** Direction: one shape, the hub's accent ring (K9), two beats on both surfaces, so "you landed here" reads the same in the browser and the panel. The Mac's fill pulse (M10) becomes a ring.

**P6. Hover card page turns snap.** Direction: a page turn slides the content a short way in the direction of travel (forward from the right, back from the left) at the fast speed; the pill row's highlight moves between pills rather than jumping. Falsifiable: a scroll over the icon shows the old page leaving and the new one arriving within 130 ms each.

**P7. Loading.** No direction: closed by R10 and R4. The hub's skeleton with shimmer is the law ("Not a spinner"), and the owner wants the visible loading animation kept ("it is the loading delay I can see it"). The Mac's delayed spinner (M9) already avoids flashing on quick saves.

**P8. Retune the hub's speeds or curve.** No direction: closed by R9 ("motion ... exactly the current values. No retuning").

## Hand-off

To `/build-ui` (hub) and the Swift build (Mac), as constraints, not authored values:

- **Sweep constraints:** the hub's tokens (H1) and keyframes K1 to K11 are precedent; the off-token literals (120 ms in hub-shared.css:96, 160 ms at T:742, 1.2 s at T:570) are out of canon and should move onto the tokens. On the Mac, `Pointer.swift`'s flash and every `withAnimation` in M1 to M10 are the sites.
- **Candidate new precedents** (approve only after the sweep runs and finds no existing answer): `Motion.swift` on the Mac; named view-transition elements for the card's dot, cost and context bar; a hover-card page slide.

For the later `/create-skill ui-animate`: the method this memo used is the skill's skeleton. Inventory every animation with file and value; read the rejection record first; name the verbs the product needs (arrive, leave, change, attention, or fewer); map each to one meaning; collapse durations onto the product's existing tokens rather than inventing new ones; give every verb a static form for reduced motion; write each resolution as a check someone else can run.

## Self-critique residue

- The first draft added a fifth verb, "settle", for scroll ends. Dropped: it is arrive, applied to a position.
- P1's choreography is a PREDICTION about how it will feel; the owner judges it on a recording, which the build round must produce.
- The view transitions support figures (W2) come from a secondary summary and are UNCONFIRMED until the build tests them in the browser the owner uses.
- Nothing here was rendered: every number is read from source (sheet section 3), and three of them were re-measured for this memo (`rg -n -- "--t-fast: 130ms" hub/lib/*.html`; `rg -n "view-transition-old\(root\)" hub/lib/hub-index.html`; `rg -c "accessibilityReduceMotion|reduceMotion" Sources` returned nothing).
