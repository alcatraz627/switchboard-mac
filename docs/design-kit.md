# The design kit

Switchboard's look comes from two small files you can copy into any AppKit or
SwiftUI menu bar app: `Sources/DesignKit.swift` and `Sources/Palette.swift`.
They have no dependencies beyond AppKit and SwiftUI. The claude-instances bar
uses the same two files, so the two apps read as one family.

This page says what is in them and the rules they encode. Copy the files, then
follow the rules; the rules matter more than the code.

## What you get

| Piece | Where | Use it for |
|---|---|---|
| `BarFont` | DesignKit | The AppKit type scale: `title`, `body`, `caption`, `monoBody`, `monoCaption`, `sectionLabel`, plus `scaled(_:)` for any other size |
| `PT` | PolicyPanel.swift | The SwiftUI twin: `title`, `label`, `caption`, `section`, `mono`, row padding, panel width |
| `seg`, `row`, `dot` | DesignKit | Build a styled line from segments instead of hand-assembling attributed strings |
| `columned` | DesignKit | Real tab-stop columns, so numbers line up without padding with spaces |
| `tailTruncate`, `middleTruncate`, `clampLines` | DesignKit | One truncation rule per kind of field |
| `makeStateBadge` | DesignKit | The on/off/count pill, contrast-checked against whatever colour it is given |
| `MenuRowView` | DesignKit | A custom menu row that actually receives clicks and draws its own hover |
| `ClosureMenuItem` | DesignKit | A menu item that runs a closure, no target/selector pair |
| `PaletteToken`, `PaletteStore` | Palette | Named colours with defaults and user overrides |
| `severityToken`, `severityColor` | DesignKit | The one green, amber, red scale every health signal shares |

## The rules

**Hierarchy is size and weight, not colour.** Three roles: a title (13pt
semibold), a body (12pt), a caption (11pt). Section headers are 10pt semibold
and tracked. Numbers and anything in columns use the monospaced system font so
digits line up. If you need a fourth size, use `BarFont.scaled(n)` so it still
follows the user's size setting.

**Every size goes through the scale.** `BarFont.scale` reads `ui.fontScale`
from preferences (0.7 to 1.6). Write `BarFont.scaled(26)` for a row height, not
`26`, or the row clips when someone turns the size up.

**Colour means something or it is not there.** Colour is reserved for state:
the severity scale (`successHigh`, `warnMid`, `warnHigh`) and a handful of
identity accents. Ask for a token (`menuGreen`, `PaletteStore.shared.color(for:
.warnHigh)`), never a hex literal, so a user override and a future dark-tuned
default both land everywhere at once.

**Badges pick their text by appearance, then fix the fill.** In light mode a
filled badge gets white text, in dark mode dark text. The fill is then nudged
away from the text until the pair clears 4.5:1. The look is chosen first and
the contrast floor is met by adjusting the colour, so no user palette can make
a badge unreadable. A disengaged state is a hollow pill (`tint: nil`), which is
what "nothing engaged" should look like.

**A view-based menu item never sends its action.** AppKit gives the mouse to
the view. Any interactive custom row must be a `MenuRowView` (or handle
`mouseUp` itself) and draw its own hover, because AppKit only highlights
standard items. This was proven with a probe before the class existed, and
`tests/fixtures/switchboard-probe.swift` keeps it proven.

**One truncation rule per field kind.** Identifiers cut at the tail. Paths cut
in the middle, keeping both meaningful ends. Prose clamps to N lines in the
label.

**Size columns by their content.** When a list has a label column, measure the
widest label and clamp it (see `labelColumn` in `App.swift`) instead of picking
a constant that silently clips the day a label grows.

## Panels (SwiftUI)

The popover is SwiftUI hosted in an `NSPopover`. `PT` in `PolicyPanel.swift`
is the SwiftUI side of the same scale. Patterns worth keeping:

- Grouped cards: a small caps section label with an SF Symbol, then rows inside
  one rounded container, hairline dividers between rows.
- Size the popover to its content up to the screen height (`ContentHeightKey`),
  so a short tab is not padded with empty space.
- Every tab can be rendered headlessly to a PNG in dark and light
  (`scripts/snapshots.sh`). Look at both before calling a UI change done.

## Adopting it in a new app

1. Copy `DesignKit.swift` and `Palette.swift` into your sources.
2. Trim `PaletteToken` to the tokens you use; keep the severity three.
3. Add `PT` from `PolicyPanel.swift` if you use SwiftUI.
4. Add a headless `--snapshot` flag early, before the UI grows, so every state
   can be checked in both appearances without clicking.
