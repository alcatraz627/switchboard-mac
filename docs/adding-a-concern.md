# Adding a tab

A tab is a **concern**: a store that knows the state, a view that shows it, and
one entry in the registry. There are two ways to build one.

- **A list tab** reads things and lists them: Hooks, Ledger, Queue, Library
  and Claude MCP. It needs one reader function per section and nothing else;
  search, opening a row, copying a path, "Show all" and hiding a section in
  Settings all come with it. Start at [A list tab](#a-list-tab) below.
- **A tab with its own controls** has state you change: Home, Notes, Timers.
  Home (the WiZ bulbs) is the smallest complete example, so read
  `Sources/Lights.swift` alongside the four steps after the list-tab section.

## A list tab

Write a reader in `Sources/CatalogReaders.swift`. Each section is a function
that returns entries, or throws a `CatalogError` whose message the section
shows in place of its rows:

```swift
enum PlugsCatalog {
    static func groups() -> [SystemGroup] {
        Catalog.sections("plugs", [("Online", online), ("Saved", saved)])
    }

    static func online() throws -> [CatalogEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CatalogError("\(abbreviateHome(path)) could not be read")
        }
        return parse(text).map { p in
            CatalogEntry(name: p.name, summary: p.room,
                         details: [("Address", p.ip), ("Seen", p.seen)], path: path, tag: p.state)
        }
    }
}
```

Then register it with `catalogTab(...)` in `SwitchboardConcerns.registry`
(`Sources/PolicyPanel.swift`), give it and each of its sections a symbol in
`Icons` (`Sources/AppSupport.swift`), place it in a space and in
`Visibility.defaultTabOrder`, and add a
`--snapshot --tab <id>` line to `tests/run-tests.sh`. The reader runs off the
main thread when the tab opens. An empty section says "Nothing here yet", and
a failed one says why, so neither ever reads as a blank tab.

## 1. The store

An `ObservableObject` that owns the state and does the slow work off the main
thread. Keep shell-outs in a helper script under `Resources/lib/` that prints
JSON, so the logic can be tested without the app:

```swift
final class PlugsStore: ObservableObject {
    @Published private(set) var plugs: [Plug] = []
    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Services.shell("/usr/bin/env", ["python3", AppPaths.lib("plugs.py"), "list"])
            let list = (try? JSONDecoder().decode([Plug].self, from: Data(out.utf8))) ?? []
            DispatchQueue.main.async { self.plugs = list }
        }
    }
}
```

`Services.shell` caps every call (4 seconds by default) and drains the pipe on
another queue, so a wedged helper can never freeze the panel.

## 2. The view

Use `PT` for type and spacing and the grouped-card layout the other tabs use
(see `docs/design-kit.md`). Show an honest empty state ("No plugs found on this
network") rather than a blank tab.

## 3. The registry entry

Add one `SwitchboardConcern` in `SwitchboardConcerns.registry` in
`Sources/PolicyPanel.swift`: an id, tab title, subtitle, SF Symbol, footer line,
the view, and a `refresh` closure that runs when the panel opens. If the tab
depends on something that may not be installed, add a check to `Integrations`
and filter it in `SwitchboardConcerns.all`.

## 4. Make it checkable

- Teach `snapshotPolicyPanel` to load your store for `--tab <id>`, then run
  `scripts/snapshots.sh` and look at the result in dark and light.
- Add the helper's input checks to `tests/run-tests.sh`. Keep them offline: a
  test must never reach a real device.
