# Roadmap

This is the one live backlog. Everything shipped is in the [changelog](../CHANGELOG.md), and past plans are in the [archive](archive/).

The app is at 0.4.0. Nothing is being built right now. The items below are deferred, each for a stated reason.

## Plugs

Paused on 2026-10-02 because the plugs were not working. Resume when they are.

Three smart plugs on the Home network, paired in the Lifelong Smart app (a branded Tuya app), should get a Plugs card under Lights on the Home tab. They speak Tuya protocol 3.4, which signs every local command with the plug's own 16-character local key, so the keys are needed once, whatever the route. Reading them from the phone failed because the phone is not rooted. A developer account is ruled out.

The route to build:

1. Log in by QR code with the Smart Life app, using Tuya's `tuya-device-sharing-sdk`, the same library Home Assistant uses. Each plug first has to be moved into Smart Life (hold its button about 5 seconds until it blinks, then add it). After one scan Switchboard talks to the plugs on the local network only.
2. A "Connect plugs" button on the Home tab shows the QR code in the panel. The keys land in Switchboard's state folder with mode 0600.
3. Control uses `tinytuya` from a private Python environment under `~/Library/Application Support/Switchboard/`, through a `plugs.py` helper that mirrors `wiz.py`.

Flashing local firmware (Cloudcutter to OpenBeken) was considered and left out, since it is model specific and can brick a plug.

## Hub, next round (owner, 2026-10-03; after the Switchboard work)

- In the hub card, make the click copy work for the ipc alias as well.
- Transcript page: "the message does not show the first message from me and the first from the agent, it starts at my second message". Example: http://127.0.0.1:5400/s/d5499ecd-85ff-4526-9b56-94204708bcec
- In the hub card preview, clicking a line of transcript text opens the transcript page at that line.
- Smooth scrolling everywhere.
- "The html view transitions in the hub pages is crude, explore adding more elements and animations to those."
- "The navbar scroll to change transcript does not work. In fact I think a lot of your slated ideas are not done." Audit hub/docs/remaining-work.md and the earlier hub plans against what is actually built, and list the gaps before building.

## csync and Switchboard together (owner, 2026-10-03; "far later")

The Android app (csync) and Switchboard should act as if they share many actions and context. It can grow step by step, and nothing gets built past step 1 before a plan, an exploration and a review audit.

1. Done 2026-10-03: the hub is reachable on the tailnet at http://aakarshs-m5-pro.tail905820.ts.net:5400/ (or http://100.65.206.85:5400/) and comes back after a restart (pm2 Start at login on). The owner pins that URL in csync or the phone browser.
2. A Bulbs screen in csync that stays in step with the Bulbs surface here.
3. Notes: each app keeps its own, and each can manage and edit the other's. Sharing must be possible, not primary.
4. More shared actions and context after that.

## Desk panels: collapse, and several in one window (owner, 2026-10-03; "/ui on this later")

- A collapse and expand view for desk panels, notably Notes and Usage.
- Combine panels into one window: cards split vertically, a divider between, each card keeping its own title row and controls.

Run through /ui after the current queue is finished and checked.

## Wheel on sliders: audit the whole app (owner, 2026-10-03, "bug for later")

On the Usage tab, the wheel over Claude's weekly "Warn at" slider also moves Codex's slider (by the same relative offset), and the wheel does nothing on the other sliders on that page ("What acts on these numbers"). Audit every slider in the app for one wheel target per slider, each moving only itself, before fixing.

## Other deferred items

- Codex warn and danger thresholds. Deferred by the owner. Do not raise it again.
- The m5air2 screenshot hang. Deferred until that Mac is available. Ask the owner then.
- Disk and cleanup tools belong in sys-monitor, not here.
- Claude agents get tools to manage Switchboard notes and their reminders for the owner (owner, 2026-10-03: "will plan and build later"). Needs its own plan first.
