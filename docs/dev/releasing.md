# Releasing

Releases are GitHub Releases with a zipped `Switchboard.app` and its SHA-256.
Versions follow semver in the `VERSION` file; `CHANGELOG.md` carries the notes.

## Cutting one

1. Move the `Unreleased` notes in `CHANGELOG.md` under a new `## X.Y.Z (date)`
   heading and set `VERSION` to `X.Y.Z`.
2. Run `tests/run-tests.sh` (and `SWITCHBOARD_PROBE_TIMERS=1` once, locally).
3. Run `scripts/release.sh`. It refuses a dirty tree or an existing tag, then
   builds, zips, tags `vX.Y.Z`, pushes the tag and creates the GitHub Release
   with that version's changelog section as the notes.

`scripts/release.sh --dry-run` does everything except tag, push and publish.

## Signing and Gatekeeper

Builds are ad-hoc signed, not notarized. A downloaded copy carries the
quarantine flag, so macOS refuses to open it the first time. Either
right-click the app and choose Open, or clear the flag:

```
xattr -dr com.apple.quarantine ~/Applications/Switchboard.app
```

Building from source (`scripts/build.sh --install`) never hits this, since
nothing was downloaded.
