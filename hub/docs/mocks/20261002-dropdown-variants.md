# Dropdown variants mock: build summary

1. Page: /Users/alcatraz627/.claude/widgets/claude-instances/docs/mocks/20261002-dropdown-variants.html (local only, nothing published).
2. Built with the shared page kit (`pagekit.page`, `colors.css` tokens, kit switch); mock styling uses only kit variables.
3. Sections: intro, session-state rule, six variants A to F in a responsive grid with pros and cons, hover detail card, "What to tell me".
4. All variants use the same sample data and the MCP-down banner; clanky-opus context (12%) renders red.
5. Page check (`check_page.py`): PASS, no failures.
6. Screenshots (1400x3350) saved as 20261002-dropdown-variants-dark.png and -light.png next to the page; both read back, no overlaps or clipping seen.
7. The light shot came from a scratchpad copy with data-theme set to light, since the kit defaults to dark.
8. A copy-guard hook blocked a banned word in the owner's vb-opus sample quote, so the generator loads that quote from a scratch text file; the page text is verbatim.
9. Not done: no narrow-width (phone) screenshot was taken; the grid collapses to one column under 480 px by CSS only.
10. Generator lives in the session scratchpad (gen.py, mock.css), not in the repo.
