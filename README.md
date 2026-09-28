<div align="center">
  <img src="assets/banner.svg" alt="Switchboard: every switch on your Mac, one click away" width="720">
</div>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/version-0.1.0-blue" alt="version 0.1.0">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license">
</p>

Switchboard is a menu bar app for the switches you would otherwise hunt for in
five places: keeping the Mac awake, which background jobs are failing, the
lights in the room, how much of your Claude and Codex quota is left, and what
your AI agents are allowed to do on your behalf. One icon, one panel, four tabs.

It is small on purpose. There is no server, no account and no cloud: the panel
reads files and runs a few short scripts when you open it or flip a switch.

## What's in the panel

| Tab | What it answers | What you can do |
|---|---|---|
| **Agents** | What may my agents do as me? | Allow, ask or block GitHub, Slack, Linear, commits, pushes, deploys and model seats, everywhere or per repo, for good or for a while |
| **Usage** | How much quota is left? | See Claude and Codex usage bars, and set where they turn amber and red |
| **Machine** | What is running, and what is switched off? | Re-arm muted guards, restart services, run a scheduled job now, keep the Mac awake, wake another machine on the network |
| **Home** | What are the lights doing? | Turn WiZ bulbs on and off, set brightness, warmth and scenes, name them |

<p align="center">
  <img src="assets/screenshots/system-dark.png" alt="Machine tab" width="300">
  <img src="assets/screenshots/usage-dark.png" alt="Usage tab" width="300">
</p>

Any plain switch can be flipped **for a while**: "Keep Awake for 2 hours",
"Kanban off until 6 PM". The timer survives a restart, and it never undoes a
change you made by hand in between.

One rule shapes every switch: a click can put a protection back, but never
take one away. The one exception, turning off a Claude Code permission prompt,
asks you first.

## Quick start

You need macOS 13 or later, the Xcode command line tools (`xcode-select --install`)
and python3.

```bash
git clone https://github.com/alcatraz627/switchboard-mac
cd switchboard-mac
scripts/build.sh --install    # builds Switchboard.app, copies it to ~/Applications, starts at login
```

Look for the three faders in your menu bar. To try it without installing,
`scripts/build.sh` builds and launches it from `build/`.

Or download the zip from [Releases](https://github.com/alcatraz627/switchboard-mac/releases).
It is not notarized, so the first time, right-click the app and choose Open
(details in [docs/releasing.md](docs/releasing.md)).

## Works best with Claude Code

Switchboard grew out of a personal Claude Code setup, and the Agents tab and
several Machine rows drive tools from that setup (a policy store, guard hooks,
a kanban server). Each is optional: when a tool is not installed, its row or
tab is not shown. On a plain Mac you get Keep Awake, schedules,
wake-on-LAN, the WiZ bulbs, and Claude usage if a statusline writes it. The
full list of what needs what is in [docs/architecture.md](docs/architecture.md#optional-integrations).

## Checking it without a screen

Every surface can be exercised headlessly, which is how the tests and the
screenshots above are made:

```bash
build/Switchboard.app/Contents/MacOS/Switchboard --dump             # Machine tab as text
build/Switchboard.app/Contents/MacOS/Switchboard --snapshot out.png --tab home --light
scripts/snapshots.sh                                                  # every tab, dark and light
tests/run-tests.sh                                                    # the suite
```

## Documentation

| Document | What it covers |
|---|---|
| [How it's put together](docs/architecture.md) | The pieces, where state lives, optional integrations, headless checks |
| [Adding a tab](docs/adding-a-concern.md) | A new concern in four steps, with the Home tab as the worked example |
| [The design kit](docs/design-kit.md) | The type scale, colour tokens and badge rules, and how to reuse them in another app |
| [Releasing](docs/releasing.md) | Versions, the changelog, `scripts/release.sh`, Gatekeeper |
| [Changelog](CHANGELOG.md) | What changed in each release |
| [v2 plan](docs/plans/20260925-switchboard-v2-plan.md) | What is being built next |

## Contributing

Issues and pull requests are welcome. Before opening one, run
`tests/run-tests.sh` and, for a UI change, `scripts/snapshots.sh`, and look at
both appearances.

## License

[MIT](LICENSE)
