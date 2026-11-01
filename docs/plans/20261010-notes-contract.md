# The notes contract has moved

The notes folder is now defined in one place for every app: `specs/notes.md` in the mnt-sync repository (GitHub `alcatraz627/mnt-sync`, cloned at `~/Code/mnt-sync`). The fixtures in `specs/notes/fixtures/` hold the exact cases, and `DECISIONS.md` beside them lists where the prose was silent.

Switchboard follows it through `Sources/NotesSpec.swift`, and `Switchboard --probe-spec` runs every fixture from the copy vendored in `tests/fixtures/notes-spec`. The old Pi-based contract that stood here is retired, and its "order is per device" rule was replaced by the shared `pos` key.
